import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'services/db_ssd_service.dart';
import 'services/lan_server_service.dart';
import 'widgets/karaoke_dialogs.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(const NmhKaraokePcApp());
}

class NmhKaraokePcApp extends StatelessWidget {
  const NmhKaraokePcApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'NMH Karaok PC Server',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF070B14),
      ),
      home: const KaraokeHomeScreen(),
    );
  }
}

class KaraokeHomeScreen extends StatefulWidget {
  const KaraokeHomeScreen({super.key});

  @override
  State<KaraokeHomeScreen> createState() => _KaraokeHomeScreenState();
}

class _KaraokeHomeScreenState extends State<KaraokeHomeScreen>
    with SingleTickerProviderStateMixin {
  final DbSsdService _service = DbSsdService();
  late final LanServerService _lanServer;
  late final Player _player;
  late final VideoController _videoController;
  late final AnimationController _bounceController;

  String _currentView = 'HOME';
  bool _showMyanmarSubPopup = false;
  bool _showNumberPopup = false;
  bool _showMenuOverlay = true;

  String _genderFilter = 'ALL';
  String _searchQuery = '';
  bool _useFullKeyboard = false;
  final TextEditingController _fullTextController = TextEditingController();
  final FocusNode _fullTextFocus = FocusNode();

  String _listHeaderTitle = '';
  List<Map<String, dynamic>> _songResults = [];
  List<Map<String, dynamic>> _artistResults = [];
  List<Map<String, dynamic>> _albumResults = [];
  List<String> _thingyanAlbums = [];
  String _selectedThingyanAlbum = '';

  int _songbookPage = 0;
  final int _songsPerBookPage = 10;

  final List<Map<String, dynamic>> _queue = [];
  Map<String, dynamic>? _currentSong;

  bool _isMuted = false;
  double _volume = 100.0;
  String _audioChannelMode = 'Stereo';
  int _selectedAudioTrackIndex = 0;

  static const List<String> _myanmarConsonants = [
    'က', 'ခ', 'ဂ', 'ဃ', 'င', 'စ', 'ဆ',
    'ဇ', 'ဈ', 'ည', 'ဋ', 'ဌ', 'ဍ', 'ဎ',
    'ဏ', 'တ', 'ထ', 'ဒ', 'ဓ', 'န', 'ပ',
    'ဖ', 'ဗ', 'ဘ', 'မ', 'ယ', 'ရ', 'လ',
    'ဝ', 'သ', 'ဟ', 'ဠ', 'အ'
  ];

  bool get _isPipView =>
      _currentView == 'SONG_LIST' ||
      _currentView == 'ALBUM_GRID' ||
      _currentView == 'ARTIST_GRID' ||
      _currentView == 'QUEUE' ||
      _currentView == 'THINGYAN';

  String _formatSongCode(Map<String, dynamic> song) {
    final c = (song['code'] ?? '').toString().trim();
    if (c.isNotEmpty) return c.replaceFirst(RegExp(r'^[aA]'), '');
    final fc = (song['file_code'] ?? '').toString().trim();
    return fc.replaceFirst(RegExp(r'^[aA]'), '');
  }
  @override
  void initState() {
    super.initState();
    _player = Player();
    _videoController = VideoController(_player);
    _bounceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);

    _lanServer = LanServerService(
      dbService: _service,
      onCommand: _handleRemoteCommand,
      getStatePayload: () => {
        'type': 'STATE',
        'currentSong': _currentSong,
        'queue': _queue,
        'volume': _volume,
        'isMuted': _isMuted,
        'audioChannelMode': _audioChannelMode,
        'selectedAudioTrackIndex': _selectedAudioTrackIndex,
        'isDbReady': _service.isDbReady,
        'scannedFileCount': _service.scannedFileCount,
      },
    );

    _initSystem();
    _lanServer.start(onReady: () {
      if (mounted) setState(() {});
    });
  }

  Future<void> _initSystem() async {
    await _service.initDatabases();
    await _service.loadSavedSsdPath();
    if (mounted) {
      setState(() {});
      _lanServer.broadcast();
    }
  }

  Future<void> _handleRemoteCommand(Map<String, dynamic> cmd) async {
    final String action = cmd['action'] ?? '';
    switch (action) {
      case 'PLAY_SONG':
        await _playSong(Map<String, dynamic>.from(cmd['song']),
            keepListOpen: _showMenuOverlay);
        break;
      case 'ADD_QUEUE':
        setState(() => _queue.add(Map<String, dynamic>.from(cmd['song'])));
        _lanServer.broadcast();
        break;
      case 'REMOVE_QUEUE':
        final int idx = cmd['index'] ?? -1;
        if (idx >= 0 && idx < _queue.length) {
          setState(() => _queue.removeAt(idx));
          _lanServer.broadcast();
        }
        break;
      case 'MOVE_QUEUE':
        final int from = cmd['from'] ?? -1;
        final int to = cmd['to'] ?? -1;
        if (from >= 0 &&
            from < _queue.length &&
            to >= 0 &&
            to < _queue.length) {
          setState(() {
            final item = _queue.removeAt(from);
            _queue.insert(to, item);
          });
          _lanServer.broadcast();
        }
        break;
      case 'PLAY_PAUSE':
        await _player.playOrPause();
        break;
      case 'STOP':
        await _player.stop();
        setState(() {
          _currentSong = null;
          _currentView = 'HOME';
          _showMenuOverlay = true;
        });
        _lanServer.broadcast();
        break;
      case 'RESTART':
        await _player.seek(Duration.zero);
        break;
      case 'SEEK_REL':
        final pos =
            _player.state.position + Duration(seconds: cmd['sec'] ?? 0);
        await _player.seek(pos < Duration.zero ? Duration.zero : pos);
        break;
      case 'NEXT':
        if (_queue.isNotEmpty) {
          final nextSong = _queue.removeAt(0);
          await _playSong(nextSong, keepListOpen: _showMenuOverlay);
        }
        break;
      case 'AUDIO_MODE':
        await _applyAudioChannel(cmd['mode'] ?? 'Stereo');
        break;
      case 'TRACK_INDEX':
        _selectSpecificAudioTrack(cmd['index'] ?? 0);
        break;
      case 'CYCLE_TRACK':
        _cycleAudioTrack();
        break;
      case 'VOLUME':
        setState(() {
          _isMuted = false;
          _volume = (cmd['vol'] as num).toDouble().clamp(0, 100);
        });
        await _player.setVolume(_volume);
        _lanServer.broadcast();
        break;
      case 'MUTE':
        setState(() => _isMuted = !_isMuted);
        await _player.setVolume(_isMuted ? 0.0 : _volume);
        _lanServer.broadcast();
        break;
      case 'APPLAUSE':
        await _playHumanCheerVoice();
        break;
    }
  }
  @override
  void dispose() {
    _lanServer.dispose();
    _bounceController.dispose();
    _fullTextController.dispose();
    _fullTextFocus.dispose();
    _player.dispose();
    super.dispose();
  }

  Future<void> _playHumanCheerVoice() async {
    try {
      final sfx = Player();
      await sfx.setVolume(100.0);
      try {
        await sfx.open(
          Media(
              'asset:///assets/CRWDApls_Applause 1 (ID 2363)_BigSoundBank.com (1).wav'),
        );
      } catch (_) {
        await sfx.open(
          Media(
              'asset:///CRWDApls_Applause 1 (ID 2363)_BigSoundBank.com (1).wav'),
        );
      }
      Future.delayed(const Duration(seconds: 4), () => sfx.dispose());
    } catch (_) {}
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          duration: Duration(seconds: 2),
          backgroundColor: Color(0xFF00B4D8),
          content: Text('👏👏👏 လက်ခုပ်တီး အားပေးသံ!',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
        ),
      );
    }
  }

  Future<void> _openArtistView() async {
    setState(() {
      _currentView = 'ARTIST_GRID';
      _showMenuOverlay = true;
      _showMyanmarSubPopup = false;
      _searchQuery = '';
      _fullTextController.clear();
    });
    final list = await _service.getDistinctArtists(
      initial: '',
      gender: _genderFilter,
      fullText: _useFullKeyboard,
    );
    if (mounted) setState(() => _artistResults = list);
  }

  Future<void> _openAlbumView() async {
    setState(() {
      _currentView = 'ALBUM_GRID';
      _showMenuOverlay = true;
      _showMyanmarSubPopup = false;
      _searchQuery = '';
      _fullTextController.clear();
    });
    final list = await _service.getDistinctAlbums(
      initial: '',
      category: 'Myanmar',
      fullText: _useFullKeyboard,
    );
    if (mounted) setState(() => _albumResults = list);
  }

  Future<void> _openSongTitleView(
      {String category = 'Myanmar', String title = 'သီချင်းအမည်'}) async {
    setState(() {
      _currentView = 'SONG_LIST';
      _showMenuOverlay = true;
      _listHeaderTitle = title;
      _showMyanmarSubPopup = false;
      _searchQuery = '';
      _fullTextController.clear();
    });
    final list = category == 'DISCO'
        ? _service.getDiscoFolderSongs(query: '')
        : await _service.searchSongs(mode: category, query: '', limit: null);
    if (mounted) setState(() => _songResults = list);
  }

  Future<void> _openSongbookView() async {
    setState(() {
      _currentView = 'SONGBOOK';
      _showMenuOverlay = true;
      _showMyanmarSubPopup = false;
      _songbookPage = 0;
    });
    final list =
        await _service.searchSongs(mode: 'ALL', query: '', limit: null);
    if (mounted) setState(() => _songResults = list);
  }

  Future<void> _openThingyanView() async {
    setState(() {
      _currentView = 'THINGYAN';
      _showMenuOverlay = true;
      _showMyanmarSubPopup = false;
    });
    final albums = await _service.getDistinctAlbums(category: 'Thingyan');
    final albumNames = albums
        .map((e) => (e['album'] ?? '').toString())
        .where((e) => e.isNotEmpty)
        .toList();
    _thingyanAlbums = albumNames;
    _selectedThingyanAlbum = albumNames.isNotEmpty ? albumNames.first : '';
    final songs = _selectedThingyanAlbum.isNotEmpty
        ? await _service.getSongsByExactField(
            field: 'album', value: _selectedThingyanAlbum)
        : await _service.searchSongs(mode: 'THINGYAN', query: '', limit: null);
    if (mounted) setState(() => _songResults = songs);
  }
  Future<void> _onSearchChanged(String val) async {
    setState(() => _searchQuery = val);
    if (_currentView == 'ARTIST_GRID') {
      final list = await _service.getDistinctArtists(
        initial: val,
        gender: _genderFilter,
        fullText: _useFullKeyboard,
      );
      if (mounted) setState(() => _artistResults = list);
    } else if (_currentView == 'ALBUM_GRID') {
      final list = await _service.getDistinctAlbums(
        initial: val,
        category: 'Myanmar',
        fullText: _useFullKeyboard,
      );
      if (mounted) setState(() => _albumResults = list);
    } else if (_currentView == 'SONG_LIST') {
      if (_listHeaderTitle == 'Disco Songs') {
        final list = _service.getDiscoFolderSongs(query: val);
        if (mounted) setState(() => _songResults = list);
      } else {
        final list = await _service.searchSongs(
          mode: 'Myanmar',
          query: val,
          fullText: _useFullKeyboard,
          limit: null,
        );
        if (mounted) setState(() => _songResults = list);
      }
    }
  }

  Future<void> _playSong(Map<String, dynamic> song,
      {bool keepListOpen = false}) async {
    final String? direct = song['direct_path']?.toString();
    final path = (direct != null && direct.isNotEmpty)
        ? direct
        : await _service.resolveSongFilePath(song);
    if (path == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.redAccent.shade700,
            content: Text(
                'သီချင်း Folder ထဲတွင် ဖိုင်မတွေ့ပါ: ${_formatSongCode(song)}'),
          ),
        );
      }
      return;
    }
    setState(() {
      _currentSong = song;
      _showMenuOverlay = keepListOpen;
      _showMyanmarSubPopup = false;
      _showNumberPopup = false;
    });
    _lanServer.broadcast();

    await _player.open(Media(path));
    await Future.delayed(const Duration(milliseconds: 350));
    await _applyAudioChannel(_audioChannelMode);
  }

  Future<void> _applyAudioChannel(String mode) async {
    setState(() => _audioChannelMode = mode);
    try {
      final dynamic platform = _player.platform;
      if (mode == 'Left') {
        await platform?.setProperty('af', 'pan=stereo|c0=c0|c1=c0');
      } else if (mode == 'Right' || mode == 'Karaoke') {
        await platform?.setProperty('af', 'pan=stereo|c0=c1|c1=c1');
      } else {
        await platform?.setProperty('af', '');
      }
    } catch (_) {}
    _lanServer.broadcast();
  }

  void _selectSpecificAudioTrack(int trackIndex) {
    final realTracks = _player.state.tracks.audio
        .where((t) => t.id != 'auto' && t.id != 'no')
        .toList();
    if (realTracks.isEmpty) return;
    final safeIdx = trackIndex.clamp(0, realTracks.length - 1);
    _selectedAudioTrackIndex = safeIdx;
    _player.setAudioTrack(realTracks[safeIdx]);
    setState(() {});
    _lanServer.broadcast();
  }

  void _cycleAudioTrack() {
    final realTracks = _player.state.tracks.audio
        .where((t) => t.id != 'auto' && t.id != 'no')
        .toList();
    if (realTracks.length <= 1) return;
    _selectSpecificAudioTrack((_selectedAudioTrackIndex + 1) % realTracks.length);
  }

  void _showAudioChannelDialog() {
    final realTracks = _player.state.tracks.audio
        .where((t) => t.id != 'auto' && t.id != 'no')
        .toList();
    KaraokeDialogs.showAudioChannelDialog(
      context: context,
      realTracks: realTracks,
      selectedTrackIndex: _selectedAudioTrackIndex,
      audioChannelMode: _audioChannelMode,
      onSelectTrack: _selectSpecificAudioTrack,
      onSelectChannelMode: _applyAudioChannel,
    );
  }
  Widget _buildMiniPipVideoBox({double height = 130}) {
    if (_currentSong == null) return const SizedBox.shrink();
    return GestureDetector(
      onTap: () => setState(() => _showMenuOverlay = false),
      child: Container(
        height: height,
        margin: const EdgeInsets.only(top: 6),
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFF00F5D4), width: 1.8),
          boxShadow: const [
            BoxShadow(
                color: Colors.black87, blurRadius: 8, offset: Offset(0, 3)),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Video(controller: _videoController, controls: NoVideoControls),
              Positioned(
                top: 4,
                right: 4,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.65),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.fullscreen,
                          color: Color(0xFF00F5D4), size: 14),
                      SizedBox(width: 2),
                      Text('အပြည့်ကြည့်ရန်',
                          style: TextStyle(color: Colors.white, fontSize: 10)),
                    ],
                  ),
                ),
              ),
              Positioned(
                left: 6,
                bottom: 4,
                right: 6,
                child: Text(
                  '${_formatSongCode(_currentSong!)} - ${_currentSong?['title'] ?? ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFFFFD166),
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    shadows: [Shadow(color: Colors.black, blurRadius: 4)],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool hasPlayingVideo = _currentSong != null;
    final bool showBackgroundVideo =
        hasPlayingVideo && !(_showMenuOverlay && _isPipView);
    final double keyboardHeight = MediaQuery.of(context).viewInsets.bottom;

    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (showBackgroundVideo)
            Positioned.fill(
              child: GestureDetector(
                onTap: () {
                  if (hasPlayingVideo) {
                    setState(() => _showMenuOverlay = !_showMenuOverlay);
                  }
                },
                child: Container(
                  color: Colors.black,
                  child: Center(child: Video(controller: _videoController)),
                ),
              ),
            ),
          if (_showMenuOverlay || !hasPlayingVideo)
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: showBackgroundVideo
                        ? [
                            const Color(0xFFCBD5E1).withOpacity(0.32),
                            const Color(0xFF64748B).withOpacity(0.38),
                            const Color(0xFF1E293B).withOpacity(0.48),
                          ]
                        : const [
                            Color(0xFFCBD5E1),
                            Color(0xFF64748B),
                            Color(0xFF1E293B)
                          ],
                    stops: const [0.0, 0.45, 1.0],
                  ),
                ),
                child: Column(
                  children: [
                    _buildTopBar(),
                    Expanded(child: _buildMainContent()),
                    _buildBottomControlBar(),
                  ],
                ),
              ),
            ),
          if (keyboardHeight > 0 && _useFullKeyboard)
            Positioned(
              left: 12,
              right: 12,
              bottom: keyboardHeight + 6,
              child: Material(
                elevation: 10,
                borderRadius: BorderRadius.circular(12),
                color: const Color(0xFF141E36),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border:
                        Border.all(color: const Color(0xFF00F5D4), width: 2),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.search, color: Color(0xFF00F5D4)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _fullTextController,
                          autofocus: true,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.bold),
                          decoration: const InputDecoration(
                            border: InputBorder.none,
                            hintText: 'ရှာလိုသော စာသား ရိုက်ထည့်ပါ...',
                            hintStyle: TextStyle(color: Colors.white54),
                            isDense: true,
                          ),
                          onChanged: _onSearchChanged,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.clear, color: Colors.redAccent),
                        onPressed: () {
                          _fullTextController.clear();
                          _onSearchChanged('');
                        },
                      ),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF00F5D4)),
                        onPressed: () => FocusScope.of(context).unfocus(),
                        child: const Text('OK',
                            style: TextStyle(
                                color: Colors.black,
                                fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (_showNumberPopup)
            KaraokeDialogs.buildNumberPopupOverlay(
              searchQuery: _searchQuery,
              onQueryChanged: (q) => setState(() => _searchQuery = q),
              onSearchSubmit: () async {
                final songs = await _service.searchSongs(
                    mode: 'NUMBER', query: _searchQuery, limit: null);
                if (mounted) {
                  setState(() {
                    _showNumberPopup = false;
                    _showMenuOverlay = true;
                    _listHeaderTitle = 'Number: $_searchQuery';
                    _songResults = songs;
                    _currentView = 'SONG_LIST';
                  });
                }
              },
              onClose: () => setState(() => _showNumberPopup = false),
            ),
        ],
      ),
    );
  }
  Widget _buildTopBar() {
    final bool isHome = _currentView == 'HOME';
    return Container(
      height: 56,
      margin: const EdgeInsets.fromLTRB(10, 6, 10, 4),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: Colors.black.withOpacity(0.65),
        border: Border.all(color: Colors.white.withOpacity(0.28), width: 1.2),
      ),
      child: Row(
        children: [
          if (isHome) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Container(
                width: 240,
                height: 46,
                decoration: BoxDecoration(
                  border: Border.all(
                      color: const Color(0xFFFFD166).withOpacity(0.65)),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Image.asset('assets/logo.png', fit: BoxFit.fill),
              ),
            ),
            if (_currentSong != null) ...[
              const SizedBox(width: 8),
              _topPillBtn(
                icon: Icons.ondemand_video_rounded,
                label: 'Video အပြည့်ကြည့်ရန်',
                active: true,
                accent: const Color(0xFF00F5D4),
                onTap: () => setState(() => _showMenuOverlay = false),
              ),
            ],
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: const Color(0xFF141E36),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF00F5D4)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.wifi, color: Color(0xFF00F5D4), size: 15),
                  const SizedBox(width: 5),
                  Text(
                    'IP: ${_lanServer.lanIp}:${_lanServer.port} (${_lanServer.clients.length})',
                    style: const TextStyle(
                        color: Color(0xFFFFD166),
                        fontWeight: FontWeight.bold,
                        fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              'DB: ${_service.isDbReady ? "OK" : "NO"} | Songs: ${_service.scannedFileCount}',
              style: const TextStyle(color: Colors.white70, fontSize: 11),
            ),
            const SizedBox(width: 6),
            _topPillBtn(
              icon: Icons.folder_open_rounded,
              label: 'သီချင်း Folder ရွေးရန်',
              active: false,
              accent: const Color(0xFF00F5D4),
              onTap: () async {
                await _service.pickAndScanSsdFolder();
                if (mounted) {
                  setState(() {});
                  _lanServer.broadcast();
                }
              },
            ),
            const SizedBox(width: 6),
            _topPillBtn(
              icon: Icons.folder_special_rounded,
              label: 'ရွေးထားသော သီချင်းများ (${_queue.length})',
              active: true,
              accent: Colors.redAccent,
              onTap: () => setState(() => _currentView = 'QUEUE'),
            ),
          ] else ...[
            if (_currentView == 'ARTIST_GRID') ...[
              _topPillBtn(
                  label: 'အားလုံး',
                  active: _genderFilter == 'ALL',
                  accent: const Color(0xFFFFD166),
                  onTap: () {
                    _genderFilter = 'ALL';
                    _openArtistView();
                  }),
              const SizedBox(width: 6),
              _topPillBtn(
                  label: 'ကျား',
                  active: _genderFilter == 'M',
                  accent: const Color(0xFF00BBF9),
                  onTap: () {
                    _genderFilter = 'M';
                    _openArtistView();
                  }),
              const SizedBox(width: 6),
              _topPillBtn(
                  label: 'မ',
                  active: _genderFilter == 'F',
                  accent: const Color(0xFFFF4D6D),
                  onTap: () {
                    _genderFilter = 'F';
                    _openArtistView();
                  }),
            ] else ...[
              Text(
                _currentView == 'SONGBOOK'
                    ? 'သီချင်းစာအုပ် (စုစုပေါင်း ${_songResults.length} ပုဒ်)'
                    : _currentView == 'THINGYAN'
                        ? 'သင်္ကြန်သီချင်းခွေများ'
                        : _currentView == 'ALBUM_GRID'
                            ? 'တေးစီးရီးများ'
                            : _listHeaderTitle,
                style: const TextStyle(
                    color: Color(0xFFFFD166),
                    fontSize: 15,
                    fontWeight: FontWeight.bold),
              ),
            ],
            const Spacer(),
            if (_currentSong != null) ...[
              _topPillBtn(
                  icon: Icons.ondemand_video_rounded,
                  label: 'Video အပြည့်ကြည့်ရန်',
                  active: true,
                  accent: const Color(0xFF00F5D4),
                  onTap: () => setState(() => _showMenuOverlay = false)),
              const SizedBox(width: 6),
            ],
            if (_listHeaderTitle != 'Disco Songs' ||
                _currentView != 'SONG_LIST') ...[
              _topPillBtn(
                  icon: Icons.person,
                  label: 'အဆိုတော်',
                  active: _currentView == 'ARTIST_GRID',
                  accent: const Color(0xFFFFD166),
                  onTap: _openArtistView),
              const SizedBox(width: 6),
              _topPillBtn(
                  icon: Icons.album,
                  label: 'တေးစီးရီး',
                  active: _currentView == 'ALBUM_GRID',
                  accent: const Color(0xFF00F5D4),
                  onTap: _openAlbumView),
              const SizedBox(width: 6),
              _topPillBtn(
                  icon: Icons.music_note,
                  label: 'သီချင်းအမည်',
                  active: _currentView == 'SONG_LIST',
                  accent: const Color(0xFF00BBF9),
                  onTap: () => _openSongTitleView(
                      category: 'Myanmar', title: 'သီချင်းအမည်')),
              const SizedBox(width: 6),
              _topPillBtn(
                  icon: Icons.menu_book,
                  label: 'သီချင်းစာအုပ်',
                  active: _currentView == 'SONGBOOK',
                  accent: const Color(0xFFFF9F1C),
                  onTap: _openSongbookView),
              const SizedBox(width: 6),
            ],
            _topPillBtn(
                icon: Icons.folder_special,
                label: 'ရွေးထားသော သီချင်းများ (${_queue.length})',
                active: true,
                accent: Colors.redAccent,
                onTap: () => setState(() => _currentView = 'QUEUE')),
          ],
        ],
      ),
    );
  }
  Widget _topPillBtn({
    IconData? icon,
    required String label,
    required bool active,
    required Color accent,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          color: active ? accent : Colors.white.withOpacity(0.1),
          border: Border.all(
              color: active ? Colors.white : accent.withOpacity(0.75)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 15, color: active ? Colors.black : accent),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: active ? Colors.black : Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMainContent() {
    switch (_currentView) {
      case 'ARTIST_GRID':
        return _buildGridWithKeyboard(isAlbum: false);
      case 'ALBUM_GRID':
        return _buildGridWithKeyboard(isAlbum: true);
      case 'SONG_LIST':
        return _buildSongListWithKeyboard();
      case 'SONGBOOK':
        return _buildSongbookTwoPageView();
      case 'THINGYAN':
        return _buildThingyanView();
      case 'QUEUE':
        return _buildQueueView();
      default:
        return _buildHomeCardsWithPopup();
    }
  }

  Widget _buildHomeCardsWithPopup() {
    return GestureDetector(
      onTap: () {
        if (_showMyanmarSubPopup) setState(() => _showMyanmarSubPopup = false);
      },
      child: Stack(
        children: [
          Center(
            child: AnimatedBuilder(
              animation: _bounceController,
              builder: (context, child) {
                final double dy =
                    math.sin(_bounceController.value * math.pi) * -6.0;
                return Transform.translate(offset: Offset(0, dy), child: child);
              },
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _buildMi7MainCard(
                    title: 'မြန်မာသီချင်းများ',
                    subtitle: 'MYANMAR',
                    icon: Icons.music_note_rounded,
                    accent: const Color(0xFFFFD166),
                    isSelected: _showMyanmarSubPopup,
                    onTap: () => setState(
                        () => _showMyanmarSubPopup = !_showMyanmarSubPopup),
                  ),
                  const SizedBox(width: 26),
                  _buildMi7MainCard(
                    title: 'Disco Songs',
                    subtitle: 'DISCO',
                    icon: Icons.album_rounded,
                    accent: const Color(0xFF00F5D4),
                    isSelected: false,
                    onTap: () => _openSongTitleView(
                        category: 'DISCO', title: 'Disco Songs'),
                  ),
                  const SizedBox(width: 26),
                  _buildMi7MainCard(
                    title: 'Number Input',
                    subtitle: 'NUMBER',
                    icon: Icons.dialpad_rounded,
                    accent: const Color(0xFFFF4D6D),
                    isSelected: _showNumberPopup,
                    onTap: () {
                      _searchQuery = '';
                      setState(() {
                        _showMyanmarSubPopup = false;
                        _showNumberPopup = true;
                      });
                    },
                  ),
                ],
              ),
            ),
          ),
          if (_showMyanmarSubPopup)
            Positioned(
              bottom: 16,
              left: 14,
              right: 14,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.arrow_drop_up,
                      color: Color(0xFFFFD166), size: 34),
                  Row(
                    children: [
                      Expanded(
                        child: _subMenuChip('အဆိုတော်', 'နာမည်ဖြင့် ရှာမည်',
                            Icons.person, const Color(0xFFFF4D6D), _openArtistView),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _subMenuChip('တေးစီးရီး', 'နာမည်ဖြင့် ရှာမည်',
                            Icons.album, const Color(0xFFFF9F1C), _openAlbumView),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _subMenuChip(
                            'သီချင်းအမည်',
                            'ဖြင့် ရှာမည်',
                            Icons.music_note,
                            const Color(0xFF00BBF9),
                            () => _openSongTitleView(
                                category: 'Myanmar', title: 'သီချင်းအမည်')),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _subMenuChip('သီချင်းစာရင်း', 'ကြည့်မည်',
                            Icons.menu_book, const Color(0xFF00F5D4), _openSongbookView),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _subMenuChip('သင်္ကြန်သီချင်း', 'များ ရှာမည်',
                            Icons.water_drop, const Color(0xFFFFD166), _openThingyanView),
                      ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
  Widget _buildMi7MainCard({
    required String title,
    required String subtitle,
    required IconData icon,
    required Color accent,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            width: 190,
            height: 125,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.white.withOpacity(isSelected ? 0.34 : 0.22),
                  accent.withOpacity(isSelected ? 0.28 : 0.14),
                  Colors.black.withOpacity(0.45),
                ],
              ),
              border: Border.all(
                color: isSelected ? Colors.white : accent.withOpacity(0.85),
                width: isSelected ? 2.5 : 1.8,
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 34, color: accent),
                const SizedBox(height: 8),
                Text(title,
                    style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Colors.white)),
                const SizedBox(height: 2),
                Text(subtitle,
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.4,
                        color: accent)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _subMenuChip(String line1, String line2, IconData icon, Color color,
      VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Colors.white.withOpacity(0.28),
              color.withOpacity(0.32),
              Colors.black.withOpacity(0.45),
            ],
          ),
          border: Border.all(color: color, width: 1.8),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(height: 4),
            Text(line1,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13)),
            Text(line2,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: color, fontWeight: FontWeight.w700, fontSize: 11)),
          ],
        ),
      ),
    );
  }

  Widget _buildSongbookTwoPageView() {
    final int totalPages =
        (_songResults.length / (_songsPerBookPage * 2)).ceil().clamp(1, 9999);
    final int startIndex = _songbookPage * _songsPerBookPage * 2;
    final leftItems =
        _songResults.skip(startIndex).take(_songsPerBookPage).toList();
    final rightItems = _songResults
        .skip(startIndex + _songsPerBookPage)
        .take(_songsPerBookPage)
        .toList();

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Column(
        children: [
          Expanded(
            child: Row(
              children: [
                Expanded(child: _buildSingleBookPage(leftItems)),
                Container(width: 4, color: Colors.black87),
                Expanded(child: _buildSingleBookPage(rightItems)),
              ],
            ),
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: 32,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: totalPages,
              itemBuilder: (context, idx) {
                final bool active = idx == _songbookPage;
                return GestureDetector(
                  onTap: () => setState(() => _songbookPage = idx),
                  child: Container(
                    width: 52,
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    decoration: BoxDecoration(
                      color: active
                          ? const Color(0xFFFFD166)
                          : Colors.white.withOpacity(0.18),
                      borderRadius: const BorderRadius.vertical(
                          bottom: Radius.circular(8)),
                      border: Border.all(color: Colors.white38),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text('Page',
                            style: TextStyle(
                                fontSize: 8,
                                color: active ? Colors.black : Colors.white70)),
                        Text('${idx + 1}',
                            style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: active ? Colors.black : Colors.white)),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
  Widget _buildSingleBookPage(List<Map<String, dynamic>> items) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFE5E7EB).withOpacity(0.94),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.black54),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            color: const Color(0xFFCBD5E1),
            child: const Row(
              children: [
                SizedBox(
                    width: 56,
                    child: Text('No',
                        style: TextStyle(
                            color: Colors.black87,
                            fontWeight: FontWeight.bold,
                            fontSize: 12))),
                Expanded(
                    flex: 6,
                    child: Text('သီချင်းအမည်',
                        style: TextStyle(
                            color: Colors.black87,
                            fontWeight: FontWeight.bold,
                            fontSize: 12))),
                Expanded(
                    flex: 4,
                    child: Text('Artist',
                        style: TextStyle(
                            color: Colors.black87,
                            fontWeight: FontWeight.bold,
                            fontSize: 12))),
              ],
            ),
          ),
          Expanded(
            child: ListView.separated(
              itemCount: items.length,
              separatorBuilder: (_, __) =>
                  const Divider(color: Colors.black12, height: 1),
              itemBuilder: (context, idx) {
                final s = items[idx];
                return InkWell(
                  onTap: () => _playSong(s),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 56,
                          child: Text(
                            _formatSongCode(s).padLeft(5, '0'),
                            style: const TextStyle(
                                color: Colors.black87,
                                fontWeight: FontWeight.bold,
                                fontSize: 11),
                          ),
                        ),
                        Expanded(
                          flex: 6,
                          child: Text(
                            (s['title'] ?? '').toString(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.black,
                                fontWeight: FontWeight.w600,
                                fontSize: 12),
                          ),
                        ),
                        Expanded(
                          flex: 4,
                          child: Text(
                            (s['artist'] ?? '').toString(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.black54, fontSize: 11),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGridWithKeyboard({required bool isAlbum}) {
    final items = isAlbum ? _albumResults : _artistResults;
    final bool hasMiniVideo = _currentSong != null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: Row(
        children: [
          Expanded(
            flex: 6,
            child: Column(
              children: [
                Expanded(
                  child: items.isEmpty
                      ? Center(
                          child: Text(
                              isAlbum
                                  ? 'တေးစီးရီး မတွေ့ပါ'
                                  : 'အဆိုတော် မတွေ့ပါ',
                              style: const TextStyle(color: Colors.white70)))
                      : GridView.builder(
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 4,
                            childAspectRatio: 0.85,
                            crossAxisSpacing: 8,
                            mainAxisSpacing: 8,
                          ),
                          itemCount: items.length,
                          itemBuilder: (context, idx) {
                            final item = items[idx];
                            final String name =
                                (isAlbum ? item['album'] : item['artist'])
                                    .toString();
                            final int photoNo = (item['id'] as int?) ?? 0;
                            return InkWell(
                              onTap: () async {
                                final songs =
                                    await _service.getSongsByExactField(
                                  field: isAlbum ? 'album' : 'artist',
                                  value: name,
                                );
                                if (mounted) {
                                  setState(() {
                                    _listHeaderTitle = name;
                                    _songResults = songs;
                                    _currentView = 'SONG_LIST';
                                  });
                                }
                              },
                              child: Container(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(14),
                                  color: Colors.white.withOpacity(0.1),
                                  border: Border.all(
                                      color: (isAlbum
                                              ? const Color(0xFF00F5D4)
                                              : const Color(0xFFFFD166))
                                          .withOpacity(0.75)),
                                ),
                                child: Column(
                                  children: [
                                    Expanded(
                                      child: FutureBuilder<Uint8List?>(
                                        future: _service.getPhotoByNo(photoNo,
                                            isAlbum: isAlbum, name: name),
                                        builder: (ctx, snap) {
                                          if (snap.hasData &&
                                              snap.data != null) {
                                            return Padding(
                                              padding: EdgeInsets.all(
                                                  isAlbum ? 6 : 0),
                                              child: isAlbum
                                                  ? ClipOval(
                                                      child: Image.memory(
                                                          snap.data!,
                                                          fit: BoxFit.cover,
                                                          width: 72,
                                                          height: 72))
                                                  : ClipRRect(
                                                      borderRadius:
                                                          const BorderRadius
                                                              .vertical(
                                                              top: Radius
                                                                  .circular(
                                                                      13)),
                                                      child: Image.memory(
                                                          snap.data!,
                                                          fit: BoxFit.cover,
                                                          width:
                                                              double.infinity),
                                                    ),
                                            );
                                          }
                                          return Center(
                                            child: Icon(
                                              isAlbum
                                                  ? Icons.album_rounded
                                                  : Icons.person_rounded,
                                              size: 42,
                                              color: isAlbum
                                                  ? const Color(0xFF00F5D4)
                                                  : const Color(0xFFFFD166),
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                    Container(
                                      width: double.infinity,
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 4, horizontal: 4),
                                      decoration: BoxDecoration(
                                        color: isAlbum
                                            ? Colors.black54
                                            : const Color(0xFFB91C1C)
                                                .withOpacity(0.85),
                                        borderRadius:
                                            const BorderRadius.vertical(
                                                bottom: Radius.circular(13)),
                                      ),
                                      child: Text(
                                        name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.white),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
                if (hasMiniVideo) _buildMiniPipVideoBox(height: 115),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(flex: 4, child: _buildKeyboardPanel()),
        ],
      ),
    );
  }
  Widget _actionSymbolBtn({
    required String label,
    required IconData icon,
    required Color bgColor,
    VoidCallback? onTap,
    double fontSize = 11,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Icon(
              icon,
              size: 20,
              color: Colors.black.withOpacity(0.18),
            ),
            Text(
              label,
              style: TextStyle(
                color: Colors.black,
                fontWeight: FontWeight.bold,
                fontSize: fontSize,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSongListWithKeyboard() {
    final bool hasMiniVideo = _currentSong != null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: Row(
        children: [
          Expanded(
            flex: 6,
            child: Column(
              children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.55),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: _songResults.isEmpty
                        ? const Center(child: Text('သီချင်း မတွေ့ပါ'))
                        : ListView.separated(
                            itemCount: _songResults.length,
                            separatorBuilder: (_, __) =>
                                const Divider(color: Colors.white12, height: 1),
                            itemBuilder: (context, idx) {
                              final s = _songResults[idx];
                              final bool isPlaying = _currentSong != null &&
                                  _currentSong!['code'] == s['code'];
                              final String codeStr = _formatSongCode(s);
                              final String albumStr =
                                  (s['album'] ?? '').toString().trim();
                              return Container(
                                color: isPlaying
                                    ? const Color(0xFF00F5D4).withOpacity(0.18)
                                    : Colors.transparent,
                                child: ListTile(
                                  dense: true,
                                  contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 0),
                                  leading: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: isPlaying
                                          ? const Color(0xFFFFD166)
                                          : Colors.white.withOpacity(0.14),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      codeStr,
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                        color: isPlaying
                                            ? Colors.black
                                            : const Color(0xFF00F5D4),
                                      ),
                                    ),
                                  ),
                                  title: Text(
                                    (s['title'] ?? '').toString(),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                      color: isPlaying
                                          ? const Color(0xFFFFD166)
                                          : Colors.white,
                                    ),
                                  ),
                                  subtitle: Text(
                                    albumStr.isNotEmpty
                                        ? '${s['artist'] ?? ''} • $albumStr'
                                        : '${s['artist'] ?? ''}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        fontSize: 11, color: Colors.white70),
                                  ),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      _actionSymbolBtn(
                                        label: 'ရွေးမည်',
                                        icon: Icons.add_circle_outline_rounded,
                                        bgColor: const Color(0xFFFFD166),
                                        onTap: () {
                                          setState(() => _queue.add(s));
                                          _lanServer.broadcast();
                                          ScaffoldMessenger.of(context)
                                              .showSnackBar(
                                            SnackBar(
                                              duration:
                                                  const Duration(seconds: 1),
                                              content: Text(
                                                  'ရွေးထားသော သီချင်းများထဲ ထည့်ပြီး: ${s['title']}'),
                                            ),
                                          );
                                        },
                                      ),
                                      const SizedBox(width: 6),
                                      _actionSymbolBtn(
                                        label: 'Play မည်',
                                        icon: Icons.play_circle_filled_rounded,
                                        bgColor: const Color(0xFF00F5D4),
                                        onTap: () =>
                                            _playSong(s, keepListOpen: true),
                                      ),
                                    ],
                                  ),
                                  onTap: () => _playSong(s, keepListOpen: true),
                                ),
                              );
                            },
                          ),
                  ),
                ),
                if (hasMiniVideo) _buildMiniPipVideoBox(height: 115),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(flex: 4, child: _buildKeyboardPanel()),
        ],
      ),
    );
  }
  Widget _buildThingyanView() {
    final bool hasMiniVideo = _currentSong != null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: Row(
        children: [
          Expanded(
            flex: 6,
            child: Column(
              children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.55),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: ListView.separated(
                      itemCount: _songResults.length,
                      separatorBuilder: (_, __) =>
                          const Divider(color: Colors.white12, height: 1),
                      itemBuilder: (context, idx) {
                        final s = _songResults[idx];
                        return ListTile(
                          dense: true,
                          leading: Text(_formatSongCode(s),
                              style: const TextStyle(
                                  color: Color(0xFF00F5D4),
                                  fontWeight: FontWeight.bold,
                                  fontSize: 11)),
                          title: Text((s['title'] ?? '').toString(),
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text((s['artist'] ?? '').toString(),
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _actionSymbolBtn(
                                label: 'ရွေးမည်',
                                icon: Icons.add_circle_outline_rounded,
                                bgColor: const Color(0xFFFFD166),
                                onTap: () {
                                  setState(() => _queue.add(s));
                                  _lanServer.broadcast();
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      duration: const Duration(seconds: 1),
                                      content: Text(
                                          'ရွေးထားသော သီချင်းများထဲ ထည့်ပြီး: ${s['title']}'),
                                    ),
                                  );
                                },
                              ),
                              const SizedBox(width: 6),
                              _actionSymbolBtn(
                                label: 'Play မည်',
                                icon: Icons.play_circle_filled_rounded,
                                bgColor: const Color(0xFF00F5D4),
                                onTap: () => _playSong(s, keepListOpen: true),
                              ),
                            ],
                          ),
                          onTap: () => _playSong(s, keepListOpen: true),
                        );
                      },
                    ),
                  ),
                ),
                if (hasMiniVideo) _buildMiniPipVideoBox(height: 115),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 4,
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.55),
                borderRadius: BorderRadius.circular(14),
                border:
                    Border.all(color: const Color(0xFFFFD166).withOpacity(0.6)),
              ),
              child: ListView.builder(
                itemCount: _thingyanAlbums.length,
                itemBuilder: (context, idx) {
                  final alb = _thingyanAlbums[idx];
                  final selected = alb == _selectedThingyanAlbum;
                  return ListTile(
                    dense: true,
                    selected: selected,
                    selectedTileColor:
                        const Color(0xFFFFD166).withOpacity(0.25),
                    leading: const Icon(Icons.spa, color: Color(0xFFFFD166)),
                    title: Text(alb,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, color: Colors.white)),
                    onTap: () async {
                      _selectedThingyanAlbum = alb;
                      final songs = await _service.getSongsByExactField(
                          field: 'album', value: alb);
                      if (mounted) setState(() => _songResults = songs);
                    },
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
  Widget _buildKeyboardPanel() {
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.62),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white24),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Container(
                  height: 30,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  alignment: Alignment.centerLeft,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: _useFullKeyboard
                      ? TextField(
                          controller: _fullTextController,
                          focusNode: _fullTextFocus,
                          style: const TextStyle(
                              color: Colors.black, fontSize: 13),
                          decoration: const InputDecoration(
                            border: InputBorder.none,
                            hintText: 'စာလုံးအပြည့် ရိုက်ပါ...',
                            hintStyle:
                                TextStyle(color: Colors.black45, fontSize: 12),
                            isDense: true,
                          ),
                          onChanged: _onSearchChanged,
                        )
                      : Text(
                          _searchQuery.isEmpty
                              ? 'အတိုကောက် ရှာရန်...'
                              : _searchQuery,
                          style: TextStyle(
                            color: _searchQuery.isEmpty
                                ? Colors.black45
                                : Colors.black,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 4),
              InkWell(
                onTap: () {
                  _fullTextController.clear();
                  _onSearchChanged('');
                },
                child: Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: Colors.redAccent,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.close, color: Colors.white, size: 17),
                ),
              ),
              const SizedBox(width: 4),
              InkWell(
                onTap: () {
                  setState(() {
                    _useFullKeyboard = !_useFullKeyboard;
                    _searchQuery = '';
                    _fullTextController.clear();
                  });
                  if (_useFullKeyboard) {
                    Future.delayed(const Duration(milliseconds: 100), () {
                      if (mounted) _fullTextFocus.requestFocus();
                    });
                  } else {
                    FocusScope.of(context).unfocus();
                  }
                },
                child: Container(
                  height: 30,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: const Color(0xFF00F5D4),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    _useFullKeyboard ? 'အတိုကောက်' : 'ကီးဘုတ်အပြည့်',
                    style: const TextStyle(
                        color: Colors.black,
                        fontWeight: FontWeight.bold,
                        fontSize: 11),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                const int cols = 7;
                const int rows = 5;
                final double cellW =
                    (constraints.maxWidth - (cols - 1) * 4) / cols;
                final double cellH =
                    (constraints.maxHeight - (rows - 1) * 4) / rows;
                return GridView.builder(
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: cols,
                    childAspectRatio: (cellW / cellH).clamp(0.5, 3.5),
                    mainAxisSpacing: 4,
                    crossAxisSpacing: 4,
                  ),
                  itemCount: _myanmarConsonants.length,
                  itemBuilder: (context, idx) {
                    final ch = _myanmarConsonants[idx];
                    return ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        padding: EdgeInsets.zero,
                        backgroundColor: const Color(0xFF1E2D52),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(6),
                          side: const BorderSide(
                              color: Color(0xFF00BBF9), width: 0.8),
                        ),
                      ),
                      onPressed: () => _onSearchChanged(_searchQuery + ch),
                      child: Text(ch,
                          style: const TextStyle(
                              fontSize: 12, fontWeight: FontWeight.bold)),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
  Widget _buildQueueView() {
    final bool hasMiniVideo = _currentSong != null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        children: [
          Expanded(
            flex: 6,
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.72),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.redAccent, width: 1.6),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      const Icon(Icons.folder_special,
                          color: Colors.redAccent),
                      const SizedBox(width: 8),
                      Text('ရွေးထားသော သီချင်းများ (${_queue.length})',
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 15)),
                      const Spacer(),
                      TextButton(
                        onPressed: () => setState(() => _currentView = 'HOME'),
                        child: const Text('ပိတ်မည်',
                            style: TextStyle(color: Color(0xFF00F5D4))),
                      ),
                    ],
                  ),
                  Expanded(
                    child: _queue.isEmpty
                        ? const Center(
                            child: Text(
                                'ရွေးထားသော သီချင်းစာရင်းထဲတွင် သီချင်းမရှိသေးပါ'))
                        : ListView.separated(
                            itemCount: _queue.length,
                            separatorBuilder: (_, __) =>
                                const Divider(color: Colors.white12, height: 1),
                            itemBuilder: (context, idx) {
                              final s = _queue[idx];
                              final String codeStr = _formatSongCode(s);
                              return ListTile(
                                dense: true,
                                leading: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withOpacity(0.14),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    codeStr,
                                    style: const TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      color: Color(0xFF00F5D4),
                                    ),
                                  ),
                                ),
                                title: Text('${idx + 1}. ${s['title']}',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white)),
                                subtitle: Text(s['artist'] ?? '',
                                    style:
                                        const TextStyle(color: Colors.white70)),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    _actionSymbolBtn(
                                      label: 'အပေါ်သို့',
                                      icon: Icons.arrow_upward_rounded,
                                      bgColor: idx > 0
                                          ? const Color(0xFFFFD166)
                                          : Colors.white24,
                                      fontSize: 10,
                                      onTap: idx > 0
                                          ? () {
                                              setState(() {
                                                final item =
                                                    _queue.removeAt(idx);
                                                _queue.insert(idx - 1, item);
                                              });
                                              _lanServer.broadcast();
                                            }
                                          : null,
                                    ),
                                    const SizedBox(width: 4),
                                    _actionSymbolBtn(
                                      label: 'အောက်သို့',
                                      icon: Icons.arrow_downward_rounded,
                                      bgColor: idx < _queue.length - 1
                                          ? const Color(0xFFFFD166)
                                          : Colors.white24,
                                      fontSize: 10,
                                      onTap: idx < _queue.length - 1
                                          ? () {
                                              setState(() {
                                                final item =
                                                    _queue.removeAt(idx);
                                                _queue.insert(idx + 1, item);
                                              });
                                              _lanServer.broadcast();
                                            }
                                          : null,
                                    ),
                                    const SizedBox(width: 4),
                                    _actionSymbolBtn(
                                      label: 'Play မည်',
                                      icon: Icons.play_circle_filled_rounded,
                                      bgColor: const Color(0xFF00F5D4),
                                      fontSize: 10,
                                      onTap: () =>
                                          _playSong(s, keepListOpen: true),
                                    ),
                                    const SizedBox(width: 4),
                                    _actionSymbolBtn(
                                      label: 'ဖျက်မည်',
                                      icon: Icons.delete_rounded,
                                      bgColor: Colors.redAccent,
                                      fontSize: 10,
                                      onTap: () {
                                        setState(() => _queue.removeAt(idx));
                                        _lanServer.broadcast();
                                      },
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ),
          if (hasMiniVideo) ...[
            const SizedBox(width: 8),
            Expanded(
              flex: 4,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Expanded(
                      child: _buildMiniPipVideoBox(height: double.infinity)),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
  Widget _buildBottomControlBar() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.82),
        border: Border(top: BorderSide(color: Colors.white.withOpacity(0.22))),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _ctrlBtn(Icons.play_arrow_rounded, 'Play/Pause', Colors.pinkAccent,
              () => _player.playOrPause()),
          _ctrlBtn(Icons.stop_rounded, 'Stop', Colors.redAccent, () {
            _player.stop();
            setState(() {
              _currentSong = null;
              _currentView = 'HOME';
              _showMenuOverlay = true;
            });
            _lanServer.broadcast();
          }),
          _ctrlBtn(Icons.repeat_rounded, 'Repeat', Colors.purpleAccent,
              () => _player.seek(Duration.zero)),
          _ctrlBtn(Icons.fast_rewind_rounded, '<<<<', Colors.lightBlueAccent,
              () {
            final pos = _player.state.position - const Duration(seconds: 10);
            _player.seek(pos < Duration.zero ? Duration.zero : pos);
          }),
          _ctrlBtn(Icons.fast_forward_rounded, '>>>>', Colors.lightBlueAccent,
              () => _player
                  .seek(_player.state.position + const Duration(seconds: 10))),
          _ctrlBtn(Icons.skip_previous_rounded, 'Re-Start', Colors.pinkAccent,
              () => _player.seek(Duration.zero)),
          _ctrlBtn(Icons.skip_next_rounded, 'Next', Colors.pinkAccent, () {
            if (_queue.isNotEmpty) {
              final nextSong = _queue.removeAt(0);
              _playSong(nextSong, keepListOpen: _showMenuOverlay);
            }
          }),
          _ctrlBtn(Icons.home_rounded, 'HOME', const Color(0xFFFFD166), () {
            setState(() {
              _currentView = 'HOME';
              _showMenuOverlay = true;
              _showMyanmarSubPopup = false;
              _showNumberPopup = false;
            });
          }, isHome: true),
          _ctrlBtn(Icons.speaker_group_rounded, _audioChannelMode,
              const Color(0xFF00F5D4), _showAudioChannelDialog),
          _ctrlBtn(
              Icons.mic_rounded,
              _selectedAudioTrackIndex == 0 ? 'Karaoke' : 'Vocal On',
              Colors.redAccent, () {
            final realTracks = _player.state.tracks.audio
                .where((t) => t.id != 'auto' && t.id != 'no')
                .toList();
            if (realTracks.length > 1) {
              _cycleAudioTrack();
            } else {
              _applyAudioChannel(
                  _audioChannelMode == 'Karaoke' ? 'Stereo' : 'Karaoke');
            }
          }),
          _ctrlBtn(Icons.volume_down_rounded, 'Volume-', Colors.cyanAccent, () {
            setState(() {
              _isMuted = false;
              _volume = (_volume - 10).clamp(0, 100);
            });
            _player.setVolume(_volume);
            _lanServer.broadcast();
          }),
          _ctrlBtn(Icons.volume_up_rounded, 'Volume+', Colors.cyanAccent, () {
            setState(() {
              _isMuted = false;
              _volume = (_volume + 10).clamp(0, 100);
            });
            _player.setVolume(_volume);
            _lanServer.broadcast();
          }),
          _ctrlBtn(Icons.volume_off_rounded, 'Mute', Colors.purpleAccent, () {
            setState(() => _isMuted = !_isMuted);
            _player.setVolume(_isMuted ? 0.0 : _volume);
            _lanServer.broadcast();
          }),
          _ctrlBtn(Icons.thumb_up_rounded, 'Like', const Color(0xFFFFD166),
              _playHumanCheerVoice),
          _ctrlBtn(Icons.power_settings_new_rounded, 'Exit', Colors.redAccent,
              () async {
            await _player.stop();
            await _player.dispose();
            exit(0);
          }),
        ],
      ),
    );
  }

  Widget _ctrlBtn(IconData icon, String label, Color color, VoidCallback onTap,
      {bool isHome = false}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: isHome ? 38 : 30,
            height: isHome ? 38 : 30,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isHome
                  ? const Color(0xFFFFD166)
                  : Colors.white.withOpacity(0.12),
              border: Border.all(
                  color: isHome ? Colors.white : color, width: 1.4),
            ),
            child: Icon(icon,
                size: isHome ? 22 : 16, color: isHome ? Colors.black : color),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              fontSize: 8.5,
              fontWeight: isHome ? FontWeight.bold : FontWeight.w500,
              color: isHome
                  ? const Color(0xFFFFD166)
                  : Colors.white.withOpacity(0.85),
            ),
          ),
        ],
      ),
    );
  }
}
















