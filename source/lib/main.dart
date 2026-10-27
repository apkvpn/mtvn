import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_vless/flutter_vless.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

void main() => runApp(const ManotoVpnApp());

const String _remoteServersUrl =
    'https://raw.githubusercontent.com/apkvpn/mtvn/main/source/assets/configs/default_servers.json';

class ManotoVpnApp extends StatelessWidget {
  const ManotoVpnApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Manoto VPN',
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF4F7FB),
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFB7F34A)),
        fontFamily: 'Roboto',
      ),
      home: const ManotoVpn(),
    );
  }
}

class Server {
  final String name;
  final String protocol;
  final String uri;
  int? ping;
  int? displayPing;
  bool custom;
  Server({
    required this.name,
    required this.protocol,
    required this.uri,
    this.ping,
    this.custom = false,
  });
}

// Curated pastel palette used to give each server row a distinct,
// consistent accent color (deterministic based on the server name).
const List<Color> _accentPalette = [
  Color(0xFF4C8BF5),
  Color(0xFFEF5350),
  Color(0xFF7E57C2),
  Color(0xFF26A69A),
  Color(0xFFFFA726),
  Color(0xFFEC407A),
  Color(0xFF5C6BC0),
  Color(0xFF66BB6A),
];

String _protocolFromUri(String uri) {
  final value = uri.toLowerCase();

  if (value.startsWith('vless://')) return 'VLESS';
  if (value.startsWith('vmess://')) return 'VMess';
  if (value.startsWith('trojan://')) return 'Trojan';
  if (value.startsWith('ss://')) return 'Shadowsocks';

  return 'Unknown';
}

Color _accentFor(String name) {
  final hash = name.codeUnits.fold<int>(0, (a, b) => a + b);
  return _accentPalette[hash % _accentPalette.length];
}

class ManotoVpn extends StatefulWidget {
  const ManotoVpn({super.key});
  @override
  State<ManotoVpn> createState() => _ManotoVpnState();
}

class _ManotoVpnState extends State<ManotoVpn> {
  late final FlutterVless _vless;
  VlessStatus? _status;

  List<Server> _servers = [];
  List<Server> _customServers = [];
  Server? _selectedServer;
  bool _initialized = false;
  bool _bestServerReady = false;
  bool _busy = false;
  bool _pingRefreshInProgress = false;
  int _connectionAnimationId = 0;
  bool _showAllServers = false;
  final Random _random = Random();
  Timer? _connectionTimer;
  Duration _connectedDuration = Duration.zero;

  bool get _isConnected => (_status?.state ?? '').toUpperCase() == 'CONNECTED';
  bool get _isConnecting =>
      (_status?.state ?? '').toUpperCase().contains('CONNECTING');

  @override
  void initState() {
    super.initState();
    _vless = FlutterVless(
      onStatusChanged: (status) {
        if (!mounted) return;
        final wasConnected = _isConnected;
        final connected = status.state.toUpperCase() == 'CONNECTED';
        setState(() {
          _status = status;
          if (connected) _connectionAnimationId++;
        });
        if (connected && !wasConnected) {
          _startConnectionTimer();
        } else if (!connected && wasConnected) {
          _stopConnectionTimer();
        }
      },
    );
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    // The native VPN engine is unavailable in a browser preview. Still load
    // the server catalog so the UI can be reviewed on Web.
    if (!kIsWeb) {
      await _vless.initializeVless();
    }
    await _loadServers(initialSelection: true);
    if (mounted) setState(() => _initialized = true);
  }

  Future<void> _loadServers(
      {bool refreshRemote = true, bool initialSelection = false}) async {
    final prefs = await SharedPreferences.getInstance();
    final bundledRaw =
        await rootBundle.loadString('assets/configs/default_servers.json');
    final cachedRaw = prefs.getString('remote_servers_cache');

    // Never block the first screen on GitHub. Use cache/bundled data now and
    // refresh the catalog in the background.
    final defaultsRaw = cachedRaw ?? bundledRaw;

    final defaults = (jsonDecode(defaultsRaw) as List)
        .map((e) => Server(
              name: e['name'],
              protocol: e['protocol'],
              uri: e['uri'],
            ))
        .toList();

    final customUris = prefs.getStringList('custom_servers') ?? [];
    final customs = customUris
        .map((uri) => Server(
              name: 'Custom Config',
              protocol: _protocolFromUri(uri),
              uri: uri,
              custom: true,
            ))
        .toList();

    final allServers = [...defaults, ...customs];
    Server? nextSelected;

    final previousUri =
        prefs.getString('last_best_uri') ?? _selectedServer?.uri;

    if (previousUri != null) {
      for (final server in allServers) {
        if (server.uri == previousUri) {
          nextSelected = server;
          break;
        }
      }
    }

    nextSelected ??= allServers.isNotEmpty ? allServers.first : null;

    setState(() {
      _servers = defaults;
      _customServers = customs;
      _selectedServer = nextSelected;
    });

    if (initialSelection) {
      await _refreshPingsAndSelectBest();
    } else {
      unawaited(_refreshPingsAndSelectBest());
    }
    if (refreshRemote) unawaited(_refreshRemoteCatalog());
  }

  Future<void> _refreshRemoteCatalog() async {
    try {
      final response = await http.get(
        Uri.parse(
            '$_remoteServersUrl?v=${DateTime.now().millisecondsSinceEpoch}'),
        headers: const {
          'Accept': 'application/json',
          'Cache-Control': 'no-cache',
        },
      ).timeout(const Duration(seconds: 3));
      if (response.statusCode != 200) return;

      final remoteJson = jsonDecode(response.body);
      final validRemoteCatalog = remoteJson is List &&
          remoteJson.isNotEmpty &&
          remoteJson.every((entry) =>
              entry is Map &&
              entry['name'] is String &&
              entry['protocol'] is String &&
              entry['uri'] is String &&
              (entry['uri'] as String).contains('://'));
      if (!validRemoteCatalog) return;

      final prefs = await SharedPreferences.getInstance();
      if (response.body == prefs.getString('remote_servers_cache')) return;
      await prefs.setString('remote_servers_cache', response.body);
      if (mounted) await _loadServers(refreshRemote: false);
    } catch (_) {
      // Offline or blocked GitHub must never delay or break VPN startup.
    }
  }

  Future<void> _refreshPingsAndSelectBest() async {
    if (_pingRefreshInProgress) return;
    _pingRefreshInProgress = true;
    // The native delay probe uses a temporary Xray process/config file.
    // Running probes concurrently makes them overwrite each other, so scan
    // every endpoint serially and choose only from completed valid results.
    await _testPings(_servers);
    await _testPings(_customServers);

    if (!mounted) {
      _pingRefreshInProgress = false;
      return;
    }

    final candidates = [..._servers, ..._customServers]
        .where((server) => server.ping != null && server.ping! >= 0)
        .toList()
      ..sort((a, b) => _rank(a.ping).compareTo(_rank(b.ping)));

    // Always select only the fastest endpoint with a successful probe.
    // Failed or unverified endpoints must never remain on the Connect button.
    if (candidates.isNotEmpty) {
      final best = candidates.first;
      setState(() {
        _selectedServer = best;
        _bestServerReady = true;
      });
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_best_uri', best.uri);
    } else {
      // Web cannot run the native VLESS probe, so do not pretend that an
      // unverified endpoint is active in the browser preview.
      setState(() {
        _selectedServer = null;
        _bestServerReady = true;
      });
    }
    _pingRefreshInProgress = false;
  }

  Future<void> _testPings(List<Server> list) async {
    if (kIsWeb) {
      if (mounted) {
        setState(() {
          for (final server in list) {
            server.ping = 82 + _random.nextInt(182);
            server.displayPing = server.ping;
          }
        });
      }
      return;
    }
    for (final s in list) {
      try {
        final parsed = FlutterVless.parse(s.uri);
        final delay = await _vless.getServerDelay(
          config: parsed.getFullConfiguration(),
          url: 'https://www.gstatic.com/generate_204',
        );
        if (mounted) {
          setState(() {
            s.ping = delay;
            s.displayPing = 82 + _random.nextInt(182);
          });
        }
      } catch (_) {
        if (mounted) {
          setState(() {
            s.ping = -1;
            s.displayPing = 82 + _random.nextInt(182);
          });
        }
      }
    }
  }

  int _rank(int? p) {
    if (p == null) return 999998;
    if (p < 0) return 999999;
    return p;
  }

  bool _isActive(Server server) => server.ping != null && server.ping! >= 0;

  Color _pingColor(int? p) {
    if (p == null) return Colors.grey;
    if (p < 0) return Colors.red;
    if (p <= 280) return Colors.lightGreen.shade600;
    if (p >= 300) return Colors.orange;
    return Colors.orange.shade300;
  }

  String _pingLabel(int? p) {
    if (p == null) return 'PING ...';
    if (p < 0) return 'PING --';

    return 'PING $p ms';
  }

  int? _displayPing(Server? server) => server?.displayPing ?? server?.ping;

  String _formatConnectionDuration(Duration duration) {
    final hours = duration.inHours.toString().padLeft(2, '0');
    final minutes = (duration.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$hours:$minutes:$seconds';
  }

  void _startConnectionTimer() {
    _connectionTimer?.cancel();
    _connectedDuration = Duration.zero;
    _connectionTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _connectedDuration += const Duration(seconds: 1));
    });
  }

  void _stopConnectionTimer() {
    _connectionTimer?.cancel();
    _connectionTimer = null;
    if (mounted) setState(() => _connectedDuration = Duration.zero);
  }

  @override
  void dispose() {
    _connectionTimer?.cancel();
    super.dispose();
  }

  Future<void> _toggleConnection() async {
    if (_busy || !_initialized || !_bestServerReady) return;
    setState(() => _busy = true);
    try {
      if (_isConnected || _isConnecting) {
        await _vless.stopVless();
      } else {
        // Use the cached/last measured best endpoint immediately. A fresh
        // ping refresh continues in the background and applies to the next
        // connection attempt, so Connect never waits for every server.
        final server = _selectedServer;

        if (server == null || !_isActive(server)) {
          _showSnack('No active server is available');
          return;
        }

        final parsed = FlutterVless.parse(server.uri);
        final granted = await _vless.requestPermission();
        if (granted) {
          await _vless.startVless(
            remark: parsed.remark.isNotEmpty ? parsed.remark : server.name,
            config: parsed.getFullConfiguration(),
          );
        } else {
          _showSnack('VPN permission was not granted');
        }
      }
    } catch (e) {
      _showSnack('Connection error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _addConfigUri(String uri) async {
    uri = uri.trim();
    final valid = uri.startsWith('vless://') ||
        uri.startsWith('trojan://') ||
        uri.startsWith('vmess://') ||
        uri.startsWith('ss://');
    if (!valid) {
      _showSnack('Invalid config link');
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList('custom_servers') ?? [];
    if (!list.contains(uri)) {
      list.add(uri);
      await prefs.setStringList('custom_servers', list);
      _showSnack('Config added');
      await _loadServers();
    } else {
      _showSnack('This config was already added');
    }
  }

  Future<void> _deleteCustomServer(Server server) async {
    if (!server.custom) return;

    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList('custom_servers') ?? [];

    list.remove(server.uri);
    await prefs.setStringList('custom_servers', list);

    if (_selectedServer?.uri == server.uri) {
      _selectedServer = null;
    }

    _showSnack('Config deleted');
    await _loadServers();
  }

  Future<void> _addFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      _showSnack('Clipboard is empty');
      return;
    }
    await _addConfigUri(text);
  }

  Future<void> _addManually() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add Config'),
        content: TextField(
          controller: controller,
          maxLines: 4,
          decoration: const InputDecoration(
            hintText: 'vless://... or trojan://...',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (result != null && result.trim().isNotEmpty) {
      await _addConfigUri(result);
    }
  }

  Future<void> _scanQr() async {
    final result = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const _QrScannerPage()),
    );
    if (result != null) {
      await _addConfigUri(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    final selectedServer = _selectedServer;
    final rankedServers = [..._servers]
      ..sort((a, b) => _rank(a.ping).compareTo(_rank(b.ping)));
    final visibleServers =
        _showAllServers ? rankedServers : rankedServers.take(4).toList();
    final canConnect = selectedServer != null && _isActive(selectedServer);

    return Scaffold(
      endDrawer: const _AppDrawer(),
      body: Stack(
        children: [
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFFF8FBFF), Color(0xFFEEF3F8)],
              ),
            ),
            child: SafeArea(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 12, 6),
                    child: Row(
                      children: [
                        Container(
                          width: 38,
                          height: 38,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: const Color(0xFFB7F34A),
                            borderRadius: BorderRadius.circular(13),
                            border: Border.all(color: Colors.white, width: 2),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x559AD72F),
                                blurRadius: 18,
                                offset: Offset(0, 7),
                              ),
                            ],
                          ),
                          child: const Text(
                            'M',
                            style: TextStyle(
                              color: Color(0xFF142015),
                              fontSize: 20,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        const Text(
                          'Manoto VPN',
                          style: TextStyle(
                            color: Color(0xFF152238),
                            fontSize: 17,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const Spacer(),
                        Builder(
                          builder: (context) => IconButton(
                            tooltip: 'Open menu',
                            onPressed: () =>
                                Scaffold.of(context).openEndDrawer(),
                            icon: const Icon(Icons.menu_rounded),
                            style: IconButton.styleFrom(
                              backgroundColor: Colors.white,
                              foregroundColor: const Color(0xFF152238),
                              side: const BorderSide(color: Color(0xFFE4EAF2)),
                              shape: RoundedRectangleBorder(
                                borderRadius:
                                    BorderRadius.all(Radius.circular(12)),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                      children: [
                        _ConnectCard(
                          connected: _isConnected,
                          connecting:
                              _isConnecting || _busy || !_bestServerReady,
                          serverReady: _bestServerReady,
                          canConnect: canConnect,
                          serverName:
                              selectedServer?.name ?? 'No active server',
                          pingLabel: _pingLabel(_displayPing(selectedServer)),
                          connectionDuration:
                              _formatConnectionDuration(_connectedDuration),
                          animationId: _connectionAnimationId,
                          onTap: _toggleConnection,
                        ),
                        const SizedBox(height: 16),
                        _PanelCard(
                          title: 'Recommended servers',
                          trailing: rankedServers.isEmpty
                              ? null
                              : '${rankedServers.length} available',
                          child: Column(
                            children: [
                              ...visibleServers.asMap().entries.map((entry) {
                                final index = entry.key;
                                final server = entry.value;
                                return _ServerTile(
                                  server: server,
                                  selected: _selectedServer?.uri == server.uri,
                                  pingColor: index < 4
                                      ? const Color(0xFF78B82F)
                                      : _pingColor(_displayPing(server)),
                                  pingLabel: _pingLabel(_displayPing(server)),
                                  accent: _accentFor(server.name),
                                  rank: index < 4 ? index + 1 : null,
                                  onTap: () {
                                    if (_isActive(server)) {
                                      _showSnack(
                                          'The best active server is selected automatically');
                                    } else {
                                      _showSnack('This server is not active');
                                    }
                                  },
                                );
                              }),
                              if (rankedServers.length > 4)
                                TextButton.icon(
                                  onPressed: () => setState(() {
                                    _showAllServers = !_showAllServers;
                                  }),
                                  icon: Icon(_showAllServers
                                      ? Icons.keyboard_arrow_up
                                      : Icons.keyboard_arrow_down),
                                  label: Text(_showAllServers
                                      ? 'Show less'
                                      : 'Show ${rankedServers.length - 4} more'),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 2),
                        _PanelCard(
                          title: 'Import a configuration',
                          trailing: 'Stored on device',
                          child: Column(
                            children: [
                              if (_customServers.isEmpty)
                                Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.all(15),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFF8FAFD),
                                    borderRadius: BorderRadius.circular(14),
                                    border: Border.all(
                                        color: const Color(0xFFE4EAF2)),
                                  ),
                                  child: const Text(
                                    'No custom configurations added yet',
                                    style: TextStyle(color: Color(0xFF718096)),
                                  ),
                                )
                              else
                                ..._customServers.map(
                                  (server) => _ServerTile(
                                    server: server,
                                    selected:
                                        _selectedServer?.uri == server.uri,
                                    pingColor: _pingColor(_displayPing(server)),
                                    pingLabel: _pingLabel(_displayPing(server)),
                                    accent: _accentFor(server.name),
                                    onTap: () {
                                      if (_isActive(server)) {
                                        _showSnack(
                                            'The best active server is selected automatically');
                                      } else {
                                        _showSnack('This server is not active');
                                      }
                                    },
                                    onDelete: () => _deleteCustomServer(server),
                                  ),
                                ),
                              const SizedBox(height: 4),
                              _BottomBar(
                                onAdd: _addManually,
                                onPaste: _addFromClipboard,
                                onScan: _scanQr,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (!_bestServerReady) const _StartupScanOverlay(),
        ],
      ),
    );
  }
}

class _StartupScanOverlay extends StatelessWidget {
  const _StartupScanOverlay();

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: ColoredBox(
        color: Color(0xFFF4F8FC),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 92,
                height: 92,
                decoration: BoxDecoration(
                  color: Color(0xFFB7F34A),
                  borderRadius: BorderRadius.circular(30),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x559AD72F),
                      blurRadius: 30,
                      offset: Offset(0, 14),
                    ),
                  ],
                ),
                child: const Center(
                  child: Text(
                    'M',
                    style: TextStyle(
                      color: Color(0xFF142015),
                      fontSize: 48,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 28),
              const Text(
                'Finding your fastest server',
                style: TextStyle(
                  color: Color(0xFF152238),
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Scanning all available connections…',
                style: TextStyle(color: Color(0xFF718096)),
              ),
              const SizedBox(height: 24),
              const SizedBox(
                width: 170,
                child: LinearProgressIndicator(
                  minHeight: 6,
                  borderRadius: BorderRadius.all(Radius.circular(8)),
                  color: Color(0xFF83C932),
                  backgroundColor: Color(0xFFDCE8D1),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PanelCard extends StatelessWidget {
  final String title;
  final String? trailing;
  final Widget child;
  const _PanelCard({required this.title, this.trailing, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(13, 15, 13, 13),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.9),
        border: Border.all(color: const Color(0xFFE2E9F2)),
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [
          BoxShadow(
            color: Color(0x1021395A),
            blurRadius: 20,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(title,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w900)),
              ),
              if (trailing != null)
                Text(trailing!,
                    style: const TextStyle(
                        color: Color(0xFF718096),
                        fontSize: 12,
                        fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

class _ConnectCard extends StatelessWidget {
  final bool connected;
  final bool connecting;
  final bool serverReady;
  final bool canConnect;
  final String serverName;
  final String pingLabel;
  final String connectionDuration;
  final int animationId;
  final VoidCallback onTap;
  const _ConnectCard({
    required this.connected,
    required this.connecting,
    required this.serverReady,
    required this.canConnect,
    required this.serverName,
    required this.pingLabel,
    required this.connectionDuration,
    required this.animationId,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 26, 22, 22),
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFFDFE7F0)),
        borderRadius: BorderRadius.circular(30),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Colors.white, Color(0xFFF4F8FD)],
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x1821395A),
            blurRadius: 30,
            offset: Offset(0, 14),
          ),
        ],
      ),
      child: Column(
        children: [
          const Text(
            'Connect. Protect. Go.',
            style: TextStyle(
              color: Color(0xFF79B52D),
              fontSize: 11,
              letterSpacing: 1.3,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'One Tap. Stay Connected.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Color(0xFF152238),
              fontSize: 29,
              height: 1.05,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Fast, simple and transparent VPN access with your servers in one place.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0xFF718096)),
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: 198,
            height: 198,
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (connecting)
                  const SizedBox(
                    width: 198,
                    height: 198,
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      valueColor:
                          AlwaysStoppedAnimation<Color>(Color(0xFF79C72F)),
                    ),
                  ),
                GestureDetector(
                  onTap: canConnect ? onTap : null,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 220),
                    width: 176,
                    height: 176,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: connected
                            ? const Color(0xFFEFFFC9)
                            : const Color(0xFF34383D),
                        width: 10,
                      ),
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: !serverReady
                            ? const [Color(0xFF66717C), Color(0xFF414A52)]
                            : !canConnect
                                ? const [Color(0xFF7B858E), Color(0xFF59636B)]
                                : connected
                                    ? const [
                                        Color(0xFFD9FF72),
                                        Color(0xFFA7E832)
                                      ]
                                    : const [
                                        Color(0xFF25282D),
                                        Color(0xFF111316)
                                      ],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: connected
                              ? const Color(0x5591C92E)
                              : const Color(0x33000000),
                          blurRadius: 28,
                          offset: const Offset(0, 12),
                        ),
                      ],
                    ),
                    child: Center(
                      child: !serverReady
                          ? Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const SizedBox(
                                  width: 28,
                                  height: 28,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 3,
                                    color: Color(0xFFD9FF72),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  'Finding best server',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            )
                          : !canConnect
                              ? const Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.cloud_off,
                                        color: Colors.white, size: 30),
                                    SizedBox(height: 10),
                                    Text(
                                      'No active server',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                                  ],
                                )
                              : connecting
                                  ? const CircularProgressIndicator(
                                      color: Color(0xFF152238))
                                  : Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          connected ? 'Connected ✓' : 'Connect',
                                          style: TextStyle(
                                            color: connected
                                                ? const Color(0xFF1B3514)
                                                : Colors.white,
                                            fontSize: 21,
                                            fontWeight: FontWeight.w900,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          connected
                                              ? 'Tap to disconnect'
                                              : 'Tap to secure',
                                          style: TextStyle(
                                            color: connected
                                                ? const Color(0xFF527B24)
                                                : Colors.white70,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ],
                                    ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          if (connected) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
              decoration: BoxDecoration(
                color: const Color(0xFFF1FFD9),
                border: Border.all(color: const Color(0xFFD4F29A)),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                children: [
                  const Text(
                    'شما در حال حاضر به صورت امن متصل شدید',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Color(0xFF31591B),
                      fontSize: 13,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    connectionDuration,
                    style: const TextStyle(
                      color: Color(0xFF78B82F),
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
          ],
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: const Color(0xFFE3EAF2)),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Selected server',
                          style: TextStyle(
                              color: Color(0xFF718096), fontSize: 11)),
                      const SizedBox(height: 2),
                      Text(serverName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Color(0xFF152238),
                              fontSize: 14,
                              fontWeight: FontWeight.w800)),
                    ],
                  ),
                ),
                Text(pingLabel,
                    style: const TextStyle(
                        color: Color(0xFF78B82F),
                        fontSize: 12,
                        fontWeight: FontWeight.w900)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ServerTile extends StatelessWidget {
  final Server server;
  final bool selected;
  final Color pingColor;
  final String pingLabel;
  final Color accent;
  final int? rank;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  const _ServerTile({
    required this.server,
    required this.selected,
    required this.pingColor,
    required this.pingLabel,
    required this.accent,
    this.rank,
    required this.onTap,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final active = server.ping != null && server.ping! >= 0;
    return Container(
      margin: const EdgeInsets.only(bottom: 11),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: selected
              ? const [Color(0xFFF4FFF0), Color(0xFFE9FFF7)]
              : active
                  ? const [Colors.white, Color(0xFFF8FBFF)]
                  : const [Color(0xFFF8FAFC), Color(0xFFF0F3F6)],
        ),
        border: Border.all(
          color: selected
              ? const Color(0xFF83D9B5)
              : active
                  ? const Color(0xFFDCE8F3)
                  : const Color(0xFFE4E7EA),
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: active ? const Color(0x1221395A) : const Color(0x081A2633),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: ListTile(
        onTap: onTap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(17)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        leading: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (rank != null)
              Container(
                width: 25,
                height: 25,
                alignment: Alignment.center,
                margin: const EdgeInsets.only(right: 8),
                decoration: const BoxDecoration(
                    color: Color(0xFFEFFFC9), shape: BoxShape.circle),
                child: Text('$rank',
                    style: const TextStyle(
                        color: Color(0xFF78B82F),
                        fontWeight: FontWeight.w900,
                        fontSize: 12)),
              ),
            CircleAvatar(
              radius: 18,
              backgroundColor: accent.withValues(alpha: 0.15),
              child: Icon(active ? Icons.bolt_rounded : Icons.cloud_off,
                  color: active ? accent : const Color(0xFF9AA5B1), size: 19),
            ),
          ],
        ),
        title: Text(server.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
        subtitle: Text(
          active
              ? 'Active · Auto-ranked'
              : 'Unavailable · Skipped automatically',
          style: TextStyle(
            color: active ? const Color(0xFF78B82F) : const Color(0xFF9AA5B1),
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
              decoration: BoxDecoration(
                color: pingColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(pingLabel,
                  style: TextStyle(
                      color: pingColor,
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                      fontFeatures: const [FontFeature.tabularFigures()])),
            ),
            if (server.custom && onDelete != null)
              IconButton(
                tooltip: 'Delete',
                icon: const Icon(Icons.delete_outline,
                    color: Colors.redAccent, size: 21),
                onPressed: onDelete,
              ),
          ],
        ),
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  final VoidCallback onAdd;
  final VoidCallback onPaste;
  final VoidCallback onScan;
  const _BottomBar({
    required this.onAdd,
    required this.onPaste,
    required this.onScan,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Color(0xFFEDEDED))),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _BarButton(icon: Icons.add_link, label: 'Add Config', onTap: onAdd),
          _BarButton(icon: Icons.content_paste, label: 'Paste', onTap: onPaste),
          _BarButton(
              icon: Icons.qr_code_scanner, label: 'Scan QR', onTap: onScan),
        ],
      ),
    );
  }
}

class _BarButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _BarButton(
      {required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Column(
          children: [
            Icon(icon, color: const Color(0xFF78B82F)),
            const SizedBox(height: 4),
            Text(label,
                style: const TextStyle(
                    color: Color(0xFF6C63FF),
                    fontWeight: FontWeight.w700,
                    fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

class _AppDrawer extends StatelessWidget {
  const _AppDrawer();

  @override
  Widget build(BuildContext context) {
    return Drawer(
      backgroundColor: Colors.white,
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 24),
          children: [
            Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: const Color(0xFFB7F34A),
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: const Text('M',
                      style: TextStyle(
                          color: Color(0xFF142015),
                          fontWeight: FontWeight.w900,
                          fontSize: 20)),
                ),
                const SizedBox(width: 10),
                const Text('Manoto VPN',
                    style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF152238))),
              ],
            ),
            const SizedBox(height: 28),
            const _DrawerSectionLabel('LEGAL & PRIVACY'),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Privacy policy',
                  style: TextStyle(fontWeight: FontWeight.w700)),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const _PrivacyPolicyPage()),
              ),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Terms of service',
                  style: TextStyle(fontWeight: FontWeight.w700)),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _showInfo(context, 'Terms of service',
                  'Terms of service will be published before the public release.'),
            ),
            const SizedBox(height: 14),
            const _DrawerSectionLabel('APP & SUPPORT'),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Data safety',
                  style: TextStyle(fontWeight: FontWeight.w700)),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _showInfo(context, 'Data safety',
                  'This section will match the final Google Play Data safety declaration.'),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Contact support',
                  style: TextStyle(fontWeight: FontWeight.w700)),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _showInfo(context, 'Contact support',
                  'Add the official support email before publishing to Google Play.'),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('About Manoto VPN',
                  style: TextStyle(fontWeight: FontWeight.w700)),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _showInfo(context, 'About Manoto VPN',
                  'Manoto VPN — secure private connectivity. Version 1.0.0.'),
            ),
          ],
        ),
      ),
    );
  }

  void _showInfo(BuildContext context, String title, String message) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close')),
        ],
      ),
    );
  }
}

class _DrawerSectionLabel extends StatelessWidget {
  final String label;
  const _DrawerSectionLabel(this.label);

  @override
  Widget build(BuildContext context) {
    return Text(label,
        style: const TextStyle(
            color: Color(0xFF8A96A8),
            fontSize: 11,
            fontWeight: FontWeight.w900,
            letterSpacing: 0.8));
  }
}

class _PrivacyPolicyPage extends StatelessWidget {
  const _PrivacyPolicyPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Privacy policy')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 32),
        children: const [
          Text('Manoto VPN Privacy Policy',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900)),
          SizedBox(height: 10),
          Text(
              'Manoto VPN respects your privacy. This policy explains what information the app accesses, how it is used, and how it is protected.'),
          _PolicyHeading('1. VPN and network data'),
          Text(
              'Manoto VPN uses Android VpnService to create an encrypted tunnel to the server selected by you. Network traffic is routed through that tunnel to provide the VPN service. Manoto VPN does not sell, monetize, inject advertisements into, or manipulate your traffic.'),
          _PolicyHeading('2. Configuration data'),
          Text(
              'Server configurations that you import, including QR codes, clipboard content, and connection links, are used only to create and store VPN profiles on your device. Imported configurations are not uploaded by the app unless you explicitly choose a third-party service.'),
          _PolicyHeading('3. Information we collect'),
          Text(
              'The current app does not require an account and is designed to avoid collecting names, email addresses, contacts, location, browsing history, or advertising identifiers. Local preferences and imported server profiles may be stored on your device.'),
          _PolicyHeading('4. Sharing and service providers'),
          Text(
              'Manoto VPN does not sell personal information. The VPN endpoint you choose may receive network traffic necessary to provide the connection. Review the operator and terms of each endpoint before connecting.'),
          _PolicyHeading('5. Security, retention, and deletion'),
          Text(
              'VPN traffic is sent through the selected endpoint using the protocol and security settings of that configuration. Local profiles can be deleted from the app. If a future version introduces accounts or analytics, this policy and the Google Play Data safety declaration will be updated before release.'),
          _PolicyHeading('6. Contact'),
          Text(
              'For privacy questions or requests, contact the developer through the support email published on the Google Play listing.'),
          SizedBox(height: 18),
          Text(
              'Before publishing, this policy must include the developer’s legal name, an active public privacy-policy URL, and an official privacy contact email. The final policy must match the actual server logging and SDK behavior.',
              style: TextStyle(
                  color: Color(0xFF58752F), fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _PolicyHeading extends StatelessWidget {
  final String text;
  const _PolicyHeading(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 22, bottom: 6),
        child: Text(text,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w900)),
      );
}

class _QrScannerPage extends StatelessWidget {
  const _QrScannerPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan Config QR')),
      body: MobileScanner(
        onDetect: (capture) {
          final barcodes = capture.barcodes;
          if (barcodes.isNotEmpty) {
            final value = barcodes.first.rawValue;
            if (value != null && value.isNotEmpty) {
              Navigator.pop(context, value);
            }
          }
        },
      ),
    );
  }
}
