import 'dart:convert';
import 'dart:io';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'db_ssd_service.dart';

class LanServerService {
  final DbSsdService dbService;
  final Future<void> Function(Map<String, dynamic> cmd) onCommand;
  final Map<String, dynamic> Function() getStatePayload;

  HttpServer? _httpServer;
  String lanIp = 'Detecting...';
  final int port = 8080;
  final Set<WebSocketChannel> clients = {};

  LanServerService({
    required this.dbService,
    required this.onCommand,
    required this.getStatePayload,
  });

  Future<void> start({required void Function() onReady}) async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      if (interfaces.isNotEmpty && interfaces.first.addresses.isNotEmpty) {
        lanIp = interfaces.first.addresses.first.address;
      } else {
        lanIp = '127.0.0.1';
      }
    } catch (_) {
      lanIp = '127.0.0.1';
    }

    final wsHandler = webSocketHandler((WebSocketChannel webSocket) {
      clients.add(webSocket);
      sendToClient(webSocket);
      webSocket.stream.listen(
        (message) async {
          try {
            final cmd = Map<String, dynamic>.from(jsonDecode(message.toString()));
            await onCommand(cmd);
          } catch (_) {}
        },
        onDone: () => clients.remove(webSocket),
        onError: (_) => clients.remove(webSocket),
      );
    });

    Future<shelf.Response> httpHandler(shelf.Request request) async {
      final path = request.url.path;
      final params = request.url.queryParameters;

      if (path == 'ws') return wsHandler(request);

      if (path == 'api/songs') {
        final mode = params['mode'] ?? 'ALL';
        final query = params['query'] ?? '';
        final fullText = params['fullText'] == 'true';
        final list = mode.toUpperCase() == 'DISCO'
            ? dbService.getDiscoFolderSongs(query: query)
            : await dbService.searchSongs(
                mode: mode, query: query, fullText: fullText, limit: null);
        return _json(list);
      }

      if (path == 'api/artists') {
        final list = await dbService.getDistinctArtists(
          initial: params['initial'] ?? '',
          gender: params['gender'] ?? 'ALL',
          fullText: params['fullText'] == 'true',
        );
        return _json(list);
      }

      if (path == 'api/albums') {
        final list = await dbService.getDistinctAlbums(
          initial: params['initial'] ?? '',
          category: params['category'] ?? 'ALL',
          fullText: params['fullText'] == 'true',
        );
        return _json(list);
      }

      if (path == 'api/songs_by_field') {
        final list = await dbService.getSongsByExactField(
          field: params['field'] ?? 'artist',
          value: params['value'] ?? '',
        );
        return _json(list);
      }

      if (path == 'api/photo') {
        final no = int.tryParse(params['no'] ?? '0') ?? 0;
        final bytes = await dbService.getPhotoByNo(no,
            isAlbum: params['isAlbum'] == 'true');
        if (bytes != null) {
          return shelf.Response.ok(bytes,
              headers: {'Content-Type': 'image/jpeg'});
        }
        return shelf.Response.notFound('No photo');
      }

      return shelf.Response.ok('NMH Karaoke PC Server Running');
    }

    try {
      _httpServer =
          await shelf_io.serve(httpHandler, InternetAddress.anyIPv4, port);
      onReady();
    } catch (_) {}
  }

  shelf.Response _json(dynamic data) => shelf.Response.ok(
        jsonEncode(data),
        headers: {'Content-Type': 'application/json; charset=utf-8'},
      );

  void sendToClient(WebSocketChannel client) {
    try {
      client.sink.add(jsonEncode(getStatePayload()));
    } catch (_) {}
  }

  void broadcast() {
    final payload = jsonEncode(getStatePayload());
    for (final c in clients.toList()) {
      try {
        c.sink.add(payload);
      } catch (_) {
        clients.remove(c);
      }
    }
  }

  void dispose() {
    _httpServer?.close(force: true);
    for (final c in clients) {
      c.sink.close();
    }
  }
}
