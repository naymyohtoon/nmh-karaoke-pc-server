import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path/path.dart' as p;

class DbSsdService {
  Database? _songDb;
  Database? _photoDb;
  String? ssdRootPath;
  Map<String, String> scannedFiles = {};

  bool get isDbReady => _songDb != null;
  int get scannedFileCount => scannedFiles.length;

  Future<void> initDatabases() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final currentDir = Directory.current.path;

    final possibleDirs = <String>[
      if (ssdRootPath != null && ssdRootPath!.isNotEmpty) ...[
        ssdRootPath!,
        Directory(ssdRootPath!).parent.path,
        p.join(ssdRootPath!, 'Database'),
      ],
      exeDir,
      currentDir,
      p.join(exeDir, 'Database'),
      p.join(currentDir, 'Database'),
      r'C:\NMHKaraoke',
      r'D:\NMHKaraoke',
      r'E:\NMHKaraoke',
    ];

    for (final dir in possibleDirs) {
      if (dir.isEmpty) continue;
      final songFile = File(p.join(dir, 'NMHSongDatabase.db3'));
      if (await songFile.exists() && _songDb == null) {
        try {
          _songDb = await databaseFactory.openDatabase(
            songFile.path,
            options: OpenDatabaseOptions(readOnly: true),
          );
        } catch (_) {}
      }

      final photoFile = File(p.join(dir, 'NMHPhotoDatabase.db3'));
      if (await photoFile.exists() && _photoDb == null) {
        try {
          _photoDb = await databaseFactory.openDatabase(
            photoFile.path,
            options: OpenDatabaseOptions(readOnly: true),
          );
        } catch (_) {}
      }

      if (_songDb != null && _photoDb != null) break;
    }
  }

  Future<void> loadSavedSsdPath() async {
    final prefs = await SharedPreferences.getInstance();
    ssdRootPath = prefs.getString('ssd_root_path');
    if (ssdRootPath != null && await Directory(ssdRootPath!).exists()) {
      await initDatabases();
      await scanSsdFolder(ssdRootPath!);
    } else {
      await autoDetectUsbDrive();
    }
  }

  Future<int> autoDetectUsbDrive() async {
    const driveLetters = ['D', 'E', 'F', 'G', 'H', 'I', 'J', 'K'];
    for (final letter in driveLetters) {
      final rootDir = Directory('$letter:\\');
      if (await rootDir.exists()) {
        final karaokeSub = Directory('$letter:\\NMHKaraoke');
        final targetPath = await karaokeSub.exists() ? karaokeSub.path : rootDir.path;
        ssdRootPath = targetPath;
        await initDatabases();
        final count = await scanSsdFolder(targetPath);
        if (count > 0 || _songDb != null) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('ssd_root_path', targetPath);
          return count;
        }
      }
    }
    return scannedFiles.length;
  }

  Future<int> pickAndScanSsdFolder() async {
    final selectedDir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'သီချင်း Folder ရွေးချယ်ပါ',
    );
    if (selectedDir != null && selectedDir.isNotEmpty) {
      ssdRootPath = selectedDir;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('ssd_root_path', selectedDir);
      await initDatabases();
      return await scanSsdFolder(selectedDir);
    }
    return scannedFiles.length;
  }

  Future<int> scanSsdFolder(String rootPath) async {
    scannedFiles.clear();
    final dir = Directory(rootPath);
    if (!await dir.exists()) return 0;

    const exts = ['.mp4', '.mkv', '.dat', '.vob', '.avi', '.mpg'];
    try {
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          final filePath = entity.path;
          final fileName = p.basename(filePath);
          final dotIndex = fileName.lastIndexOf('.');
          if (dotIndex != -1) {
            final name = fileName.substring(0, dotIndex).toLowerCase();
            final ext = fileName.substring(dotIndex).toLowerCase();
            if (exts.contains(ext)) {
              scannedFiles[name] = filePath;
            }
          }
        }
      }
    } catch (_) {}
    return scannedFiles.length;
  }

  Future<List<Map<String, dynamic>>> searchSongs({
    String mode = 'ALL',
    String query = '',
    bool fullText = false,
    int? limit,
  }) async {
    if (_songDb == null) return [];
    final List<String> whereClauses = [];
    final List<dynamic> whereArgs = [];
    final q = query.trim();
    final m = mode.toUpperCase();

    if (m == 'DISCO') {
      whereClauses.add("(LOWER(album_name) LIKE '%disco%' OR LOWER(title) LIKE '%disco%')");
    } else if (m == 'THINGYAN') {
      whereClauses.add("(album_name LIKE '%သင်္ကြန်%' OR LOWER(album_name) LIKE '%thingyan%')");
    }

    if (q.isNotEmpty) {
      if (m == 'NUMBER' || m == 'CODE') {
        whereClauses.add('(code LIKE ? OR CAST(song_no AS TEXT) LIKE ?)');
        whereArgs.addAll(['%$q%', '%$q%']);
      } else if (fullText) {
        whereClauses.add('(title LIKE ? OR artist_name LIKE ? OR album_name LIKE ?)');
        whereArgs.addAll(['%$q%', '%$q%', '%$q%']);
      } else {
        whereClauses.add(
          '(code LIKE ? OR initials LIKE ? OR title LIKE ? OR artist_name LIKE ? OR album_name LIKE ?)',
        );
        whereArgs.addAll(['%$q%', '$q%', '%$q%', '%$q%', '%$q%']);
      }
    }

    final whereString = whereClauses.isNotEmpty ? whereClauses.join(' AND ') : null;
    final rows = await _songDb!.query(
      'songs',
      where: whereString,
      whereArgs: whereArgs,
      orderBy: 'song_no ASC',
      limit: limit,
    );

    return rows.map((r) => {
      ...r,
      'artist': r['artist_name'] ?? '',
      'album': r['album_name'] ?? '',
    }).toList();
  }

  Future<List<Map<String, dynamic>>> getDistinctArtists({
    String initial = '',
    String gender = 'ALL',
    bool fullText = false,
  }) async {
    if (_songDb == null) return [];
    try {
      final List<String> whereClauses = ["TRIM(artist_name) != ''"];
      final List<dynamic> whereArgs = [];

      if (gender == 'M') {
        whereClauses.add('gender = 1');
      } else if (gender == 'F') {
        whereClauses.add('gender = 0');
      }

      if (initial.isNotEmpty) {
        if (fullText) {
          whereClauses.add('artist_name LIKE ?');
          whereArgs.add('%$initial%');
        } else {
          whereClauses.add('(initials LIKE ? OR artist_name LIKE ?)');
          whereArgs.addAll(['$initial%', '$initial%']);
        }
      }

      final rows = await _songDb!.query(
        'artists',
        where: whereClauses.join(' AND '),
        whereArgs: whereArgs,
        orderBy: 'artist_name ASC',
      );

      return rows.map((r) => {
        'id': r['artist_no'] ?? 0,
        'artist_no': r['artist_no'] ?? 0,
        'artist': r['artist_name'] ?? '',
        'gender': r['gender'] ?? 0,
      }).toList();
    } catch (_) {
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> getDistinctAlbums({
    String initial = '',
    String category = 'ALL',
    bool fullText = false,
  }) async {
    if (_songDb == null) return [];
    try {
      final List<String> whereClauses = ["TRIM(album_name) != ''"];
      final List<dynamic> whereArgs = [];

      if (category.toUpperCase() == 'THINGYAN') {
        whereClauses.add("(album_name LIKE '%သင်္ကြန်%' OR LOWER(album_name) LIKE '%thingyan%')");
      }

      if (initial.isNotEmpty) {
        if (fullText) {
          whereClauses.add('album_name LIKE ?');
          whereArgs.add('%$initial%');
        } else {
          whereClauses.add('(initials LIKE ? OR album_name LIKE ?)');
          whereArgs.addAll(['$initial%', '$initial%']);
        }
      }

      final rows = await _songDb!.query(
        'albums',
        where: whereClauses.join(' AND '),
        whereArgs: whereArgs,
        orderBy: 'album_name ASC',
      );

      return rows.map((r) => {
        'id': r['album_no'] ?? 0,
        'album_no': r['album_no'] ?? 0,
        'album': r['album_name'] ?? '',
      }).toList();
    } catch (_) {
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> getSongsByExactField({
    required String field,
    required String value,
  }) async {
    if (_songDb == null) return [];
    final cleanVal = value.trim();
    final dbCol = field == 'artist'
        ? 'artist_name'
        : (field == 'album' ? 'album_name' : field);

    final exact = await _songDb!.query(
      'songs',
      where: 'TRIM($dbCol) = ?',
      whereArgs: [cleanVal],
      orderBy: 'song_no ASC',
    );
    final rows = exact.isNotEmpty
        ? exact
        : await _songDb!.query(
            'songs',
            where: '$dbCol LIKE ?',
            whereArgs: ['%$cleanVal%'],
            orderBy: 'song_no ASC',
          );

    return rows.map((r) => {
      ...r,
      'artist': r['artist_name'] ?? '',
      'album': r['album_name'] ?? '',
    }).toList();
  }

  Uint8List? _cleanImageBytes(Uint8List raw) {
    if (raw.length < 16) return null;
    for (int i = 0; i < raw.length - 4 && i < 256; i++) {
      if (raw[i] == 0xFF && raw[i + 1] == 0xD8 && raw[i + 2] == 0xFF) {
        return raw.sublist(i);
      }
      if (raw[i] == 0x89 && raw[i + 1] == 0x50 && raw[i + 2] == 0x4E && raw[i + 3] == 0x47) {
        return raw.sublist(i);
      }
      if (raw[i] == 0x42 && raw[i + 1] == 0x4D) {
        return raw.sublist(i);
      }
    }
    return raw;
  }

  Future<Uint8List?> getPhotoByNo(int no, {bool isAlbum = false, String? name}) async {
    if (_photoDb == null || no <= 0) return null;
    final tables = isAlbum
        ? ['MainAlbum_Myanmar', 'Album_Myanmar']
        : ['MainArtist_Myanmar', 'Artist_Myanmar'];

    for (final table in tables) {
      try {
        final rows = await _photoDb!.query(
          table,
          columns: ['Data'],
          where: 'No = ? AND Data IS NOT NULL',
          whereArgs: [no],
          limit: 1,
        );
        if (rows.isNotEmpty && rows.first['Data'] is Uint8List) {
          return _cleanImageBytes(rows.first['Data'] as Uint8List);
        }
      } catch (_) {}
    }
    return null;
  }

  Future<String?> resolveSongFilePath(Map<String, dynamic> song) async {
    final String rawCode = (song['code'] ?? '').toString().trim().toLowerCase();
    final String numOnly = rawCode.replaceAll(RegExp(r'[^0-9]'), '');
    final String numNoLeadingZero = numOnly.replaceFirst(RegExp(r'^0+'), '');

    final candidates = <String>{
      if (rawCode.isNotEmpty) rawCode,
      if (numOnly.isNotEmpty) numOnly,
      if (numOnly.isNotEmpty) 'a$numOnly',
      if (numNoLeadingZero.isNotEmpty) numNoLeadingZero,
      if (numNoLeadingZero.isNotEmpty) 'a$numNoLeadingZero',
      if (numNoLeadingZero.isNotEmpty) 'a${numNoLeadingZero.padLeft(5, '0')}',
      if (numNoLeadingZero.isNotEmpty) 'a${numNoLeadingZero.padLeft(6, '0')}',
    };

    for (final key in candidates) {
      final found = scannedFiles[key];
      if (found != null && await File(found).exists()) {
        return found;
      }
    }
    return null;
  }

  List<Map<String, dynamic>> getDiscoFolderSongs({String query = ''}) {
    final List<Map<String, dynamic>> results = [];
    final q = query.trim().toLowerCase();
    int idx = 1;

    scannedFiles.forEach((key, fullPath) {
      final lowerPath = fullPath.toLowerCase();
      if (lowerPath.contains('/disco') || lowerPath.contains('\\disco')) {
        final fileName = p.basename(fullPath);
        final title = fileName.replaceFirst(RegExp(r'\.[^.]+$'), '');
        if (q.isEmpty || title.toLowerCase().contains(q)) {
          results.add({
            'code': 'D${idx.toString().padLeft(3, '0')}',
            'title': title,
            'artist': 'Disco Songs',
            'album': 'Disco',
            'direct_path': fullPath,
          });
          idx++;
        }
      }
    });
    return results;
  }
}
