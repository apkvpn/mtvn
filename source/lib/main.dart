import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_vless/flutter_vless.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

void main() => runApp(const ManotoVpnApp());

final ValueNotifier<ThemeMode> _themeMode = ValueNotifier(ThemeMode.light);

const String _remoteServersUrl =
    'https://raw.githubusercontent.com/apkvpn/mtvn/main/source/assets/configs/default_servers.json';

class ManotoVpnApp extends StatelessWidget {
  const ManotoVpnApp({super.key});
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: _themeMode,
      builder: (context, mode, _) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Manoto VPN',
        themeMode: mode,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.light,
          scaffoldBackgroundColor: const Color(0xFFF4F7FB),
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFB7F34A)),
          fontFamily: 'Roboto',
        ),
        darkTheme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFFB7F34A),
            brightness: Brightness.dark,
          ),
          fontFamily: 'Roboto',
        ),
        home: const ManotoVpn(),
      ),
    );
  }
}

class Server {
  final String name;
  final String protocol;
  final String uri;
  int? ping;
  String health = 'checking';
  DateTime? lastChecked;
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
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  VlessStatus? _status;

  List<Server> _servers = [];
  List<Server> _customServers = [];
  Server? _selectedServer;
  bool _initialized = false;
  bool _bestServerReady = true;
  bool _busy = false;
  bool _pingRefreshInProgress = false;
  int _connectionAnimationId = 0;
  bool _showAllServers = false;
  bool _autoConnect = false;
  bool _killSwitch = true;
  bool _splitTunneling = false;
  bool _threatProtection = true;
  String? _subscriptionUrl;
  DateTime? _connectedAt;
  final List<String> _connectionLog = [];

  bool get _isConnected => (_status?.state ?? '').toUpperCase() == 'CONNECTED';
  bool get _isConnecting =>
      (_status?.state ?? '').toUpperCase().contains('CONNECTING');

  @override
  void initState() {
    super.initState();
    _vless = FlutterVless(
      onStatusChanged: (status) {
        if (!mounted) return;
        final connected = status.state.toUpperCase() == 'CONNECTED';
        setState(() {
          _status = status;
          if (connected) {
            _connectedAt ??= DateTime.now();
            _connectionLog.insert(0, 'Secure tunnel connected');
          } else if (status.state.toUpperCase().contains('DISCONNECTED')) {
            _connectedAt = null;
            _connectionLog.insert(0, 'Tunnel disconnected');
          }
          if (connected) _connectionAnimationId++;
        });
      },
    );
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen(
      (results) => _onConnectivityChanged(results),
    );
    _bootstrap();
  }

  @override
  void dispose() {
    _connectivitySubscription?.cancel();
    super.dispose();
  }

  Future<void> _onConnectivityChanged(List<ConnectivityResult> results) async {
    if (!_autoConnect || _isConnected || _busy || !mounted) return;
    final online = results.any((r) => r != ConnectivityResult.none);
    if (online && _initialized && _selectedServer != null) {
      await _connectWithFallback(_selectedServer!);
    }
  }

  Future<void> _setAutoConnect(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auto_connect', value);
    if (mounted) setState(() => _autoConnect = value);
  }

  Future<void> _setSecurityOption(String key, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
    if (!mounted) return;
    setState(() {
      if (key == 'kill_switch') _killSwitch = value;
      if (key == 'split_tunneling') _splitTunneling = value;
      if (key == 'threat_protection') _threatProtection = value;
    });
  }

  Future<void> _addSubscription() async {
    final controller = TextEditingController(text: _subscriptionUrl ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add subscription'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: 'Subscription URL',
            hintText: 'https://example.com/subscription',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: const Text('Save')),
        ],
      ),
    );
    controller.dispose();
    if (result == null || result.trim().isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('subscription_url', result.trim());
    if (!mounted) return;
    setState(() {
      _subscriptionUrl = result.trim();
      _connectionLog.insert(0, 'Subscription saved locally');
    });
    _showSnack('Subscription saved. Refresh it from Settings.');
  }

  Future<void> _bootstrap() async {
    // The native VPN engine is unavailable in a browser preview. Still load
    // the server catalog so the UI can be reviewed on Web.
    if (!kIsWeb) {
      await _vless.initializeVless();
    }
    final prefs = await SharedPreferences.getInstance();
    _autoConnect = prefs.getBool('auto_connect') ?? false;
    _killSwitch = prefs.getBool('kill_switch') ?? true;
    _splitTunneling = prefs.getBool('split_tunneling') ?? false;
    _threatProtection = prefs.getBool('threat_protection') ?? true;
    _subscriptionUrl = prefs.getString('subscription_url');
    final dark = prefs.getBool('dark_mode');
    if (dark != null) _themeMode.value = dark ? ThemeMode.dark : ThemeMode.light;
    await _loadServers(initialSelection: true);
    if (mounted) setState(() => _initialized = true);
    if (_autoConnect && _selectedServer != null) {
      await _connectWithFallback(_selectedServer!);
    }
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

    unawaited(_refreshPingsAndSelectBest());
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

  // ---------------------------------------------------------------------------
  // Smart server selection ("Manoto Score")
  //
  // 1. Instant pick: the cached score from previous sessions selects a server
  //    with zero wait.
  // 2. Parallel race: every endpoint gets 3 concurrent TCP handshake probes
  //    (no Xray process, so they are safe to run all at once). ~1s total.
  // 3. Score = median latency + 0.5*jitter + loss penalty, blended with
  //    an EWMA of history and a reliability factor from real connections.
  // 4. Refinement: the top 3 get a real HTTPS delay test through the tunnel
  //    engine (serial) to confirm the winner.
  // Lower score = better.
  // ---------------------------------------------------------------------------
  final Map<String, double> _scoreCache = {};
  final Map<String, double> _reliability = {}; // 0..1, success ratio EWMA

  double _score(Server s) => _scoreCache[s.uri] ?? 999999;

  Future<void> _loadScoreHistory() async {
    final prefs = await SharedPreferences.getInstance();
    try {
      final raw = prefs.getString('score_cache');
      if (raw != null) {
        (jsonDecode(raw) as Map).forEach(
            (k, v) => _scoreCache[k as String] = (v as num).toDouble());
      }
      final rel = prefs.getString('reliability');
      if (rel != null) {
        (jsonDecode(rel) as Map).forEach(
            (k, v) => _reliability[k as String] = (v as num).toDouble());
      }
    } catch (_) {}
  }

  Future<void> _saveScoreHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('score_cache', jsonEncode(_scoreCache));
    await prefs.setString('reliability', jsonEncode(_reliability));
  }

  void _recordConnectResult(Server s, bool ok) {
    final prev = _reliability[s.uri] ?? 0.8;
    _reliability[s.uri] = prev * 0.7 + (ok ? 1.0 : 0.0) * 0.3;
    unawaited(_saveScoreHistory());
  }

  ({String host, int port})? _endpointOf(String uri) {
    try {
      if (uri.startsWith('vmess://')) {
        var b = uri.substring(8).trim();
        b = b.padRight((b.length + 3) ~/ 4 * 4, '=');
        final j = jsonDecode(utf8.decode(base64.decode(b))) as Map;
        return (host: '${j['add']}', port: int.parse('${j['port']}'));
      }
      final u = Uri.parse(uri);
      if (u.host.isEmpty) return null;
      return (host: u.host, port: u.hasPort ? u.port : 443);
    } catch (_) {
      return null;
    }
  }

  Future<int?> _tcpProbe(String host, int port) async {
    final sw = Stopwatch()..start();
    try {
      final sock = await Socket.connect(host, port,
          timeout: const Duration(milliseconds: 1500));
      sw.stop();
      sock.destroy();
      return sw.elapsedMilliseconds;
    } catch (_) {
      return null;
    }
  }

  Future<void> _probeServer(Server s) async {
    final ep = _endpointOf(s.uri);
    if (ep == null) return;
    final results = await Future.wait(
        List.generate(3, (_) => _tcpProbe(ep.host, ep.port)));
    final ok = results.whereType<int>().toList()..sort();
    final loss = 1 - ok.length / results.length;
    double fresh;
    if (ok.isEmpty) {
      fresh = 5000;
    } else {
      final median = ok[ok.length ~/ 2].toDouble();
      final jitter = (ok.last - ok.first).toDouble();
      fresh = median + 0.5 * jitter + loss * 600;
    }
    final rel = _reliability[s.uri] ?? 0.8;
    fresh = fresh / math.max(0.2, rel);
    final old = _scoreCache[s.uri];
    _scoreCache[s.uri] = old == null ? fresh : old * 0.3 + fresh * 0.7;
    if (mounted) {
      setState(() {
        s.ping = ok.isEmpty ? -1 : ok[ok.length ~/ 2];
        s.health = ok.isEmpty
            ? 'offline'
            : s.ping! > 300
                ? 'weak'
                : 'online';
        s.lastChecked = DateTime.now();
      });
    }
  }

  void _applyBest() {
    if (_isConnected || _busy) return;
    final all = [..._servers, ..._customServers]
      ..sort((a, b) => _score(a).compareTo(_score(b)));
    if (all.isEmpty || !_scoreCache.containsKey(all.first.uri)) return;
    setState(() => _selectedServer = all.first);
  }

  Future<void> _refreshPingsAndSelectBest() async {
    if (_pingRefreshInProgress || kIsWeb) return;
    _pingRefreshInProgress = true;
    try {
      if (_scoreCache.isEmpty) await _loadScoreHistory();
      _applyBest(); // instant pick from history
      final all = [..._servers, ..._customServers];
      // Parallel race, capped so the whole scan is ~1.5s worst case.
      await Future.wait(all.map(_probeServer))
          .timeout(const Duration(seconds: 3), onTimeout: () => []);
      _applyBest();
      // Refine top 3 with a real tunnel delay test.
      final top = [...all]..sort((a, b) => _score(a).compareTo(_score(b)));
      for (final s in top.take(3)) {
        if (_isConnected || _busy || !mounted) break;
        try {
          final d = await _vless
              .getServerDelay(
                config: FlutterVless.parse(s.uri).getFullConfiguration(),
                url: 'https://www.gstatic.com/generate_204',
              )
              .timeout(const Duration(seconds: 2));
          if (d > 0) {
            _scoreCache[s.uri] = _score(s) * 0.4 + d * 0.6;
          } else {
            _scoreCache[s.uri] = _score(s) * 1.5;
          }
        } catch (_) {
          _scoreCache[s.uri] = _score(s) * 1.5;
        }
      }
      _applyBest();
      final best = _selectedServer;
      if (best != null) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('last_best_uri', best.uri);
      }
      await _saveScoreHistory();
    } finally {
      _pingRefreshInProgress = false;
    }
  }

  int _rank(int? p) {
    if (p == null) return 999998;
    if (p < 0) return 999999;
    return p;
  }

  Color _pingColor(int? p) {
    if (p == null) return Colors.grey;
    if (p < 0) return Colors.lightGreen.shade600;
    if (p <= 280) return Colors.lightGreen.shade600;
    if (p >= 300) return Colors.orange;
    return Colors.orange.shade300;
  }

  String _pingLabel(int? p) {
    if (p == null) return 'CHECKING';
    if (p < 0) return 'OFFLINE';

    return 'PING $p ms';
  }

  Future<bool> _waitConnected(Duration timeout) async {
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      if (_isConnected) return true;
      await Future.delayed(const Duration(milliseconds: 120));
    }
    return _isConnected;
  }

  /// Connects to [first]; if it does not come up, automatically falls back to
  /// the next servers (fastest first) so a connection is always established.
  Future<void> _connectWithFallback(Server first) async {
    final granted = await _vless.requestPermission();
    if (!granted) {
      _showSnack('VPN permission was not granted');
      return;
    }
    final ordered = [..._servers, ..._customServers]
      ..sort((a, b) => _score(a).compareTo(_score(b)));
    final queue = [first, ...ordered.where((s) => s.uri != first.uri)];
    for (final server in queue) {
      if (!mounted) return;
      setState(() => _selectedServer = server);
      try {
        if (_isConnected || _isConnecting) {
          await _vless.stopVless();
          await Future.delayed(const Duration(milliseconds: 400));
        }
        final parsed = FlutterVless.parse(server.uri);
        await _vless.startVless(
          remark: parsed.remark.isNotEmpty ? parsed.remark : server.name,
          config: parsed.getFullConfiguration(),
        );
        final ok = await _waitConnected(const Duration(seconds: 6));
        _recordConnectResult(server, ok);
        if (ok) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('last_best_uri', server.uri);
          return;
        }
      } catch (_) {
        _recordConnectResult(server, false);
        // Try the next server.
      }
    }
    _showSnack('Could not connect. Check your internet and try again.');
  }

  Future<void> _toggleConnection() async {
    if (_busy || !_initialized) return;
    setState(() => _busy = true);
    try {
      if (_isConnected || _isConnecting) {
        await _vless.stopVless();
      } else {
        final server = _selectedServer ??
            (_servers.isNotEmpty ? _servers.first : null);
        if (server == null) {
          _showSnack('No server available');
          return;
        }
        await _connectWithFallback(server);
      }
    } catch (e) {
      _showSnack('Connection error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Manual switch: tapping a server makes it the active one and connects.
  Future<void> _switchTo(Server server) async {
    if (_busy) return;
    setState(() {
      _selectedServer = server;
      _busy = true;
    });
    try {
      await _connectWithFallback(server);
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
    final rankedServers = _servers
        .where((s) => s.uri != selectedServer?.uri)
        .toList()
      ..sort((a, b) => _score(a).compareTo(_score(b)));
    final visibleServers =
        _showAllServers ? rankedServers : rankedServers.take(4).toList();

    return Scaffold(
      endDrawer: _AppDrawer(
        autoConnect: _autoConnect,
        onAutoConnectChanged: _setAutoConnect,
      ),
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
                        _HeaderStatus(
                          connected: _isConnected,
                          connecting: _isConnecting || _busy,
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
                          connecting: _isConnecting || _busy,
                          serverReady: _bestServerReady,
                          serverName: selectedServer?.name ?? 'Loading...',
                          pingLabel: _pingLabel(selectedServer?.ping),
                          animationId: _connectionAnimationId,
                          onTap: _toggleConnection,
                        ),
                        const SizedBox(height: 12),
                        _PremiumStatsCard(
                          connected: _isConnected,
                          connectedAt: _connectedAt,
                          privacyScore: _threatProtection && _killSwitch ? 98 : 82,
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
                                  pingColor: index < 5
                                      ? const Color(0xFF78B82F)
                                      : _pingColor(server.ping),
                                  pingLabel: _pingLabel(server.ping),
                                  accent: _accentFor(server.name),
                                  rank: index == 0 ? 1 : null,
                                  onTap: () => _switchTo(server),
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
                                    pingColor: _pingColor(server.ping),
                                    pingLabel: _pingLabel(server.ping),
                                    accent: _accentFor(server.name),
                                    onTap: () => _switchTo(server),
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
                        const SizedBox(height: 12),
                        _SecurityControlsCard(
                          killSwitch: _killSwitch,
                          splitTunneling: _splitTunneling,
                          threatProtection: _threatProtection,
                          onKillSwitch: (v) => _setSecurityOption('kill_switch', v),
                          onSplitTunneling: (v) =>
                              _setSecurityOption('split_tunneling', v),
                          onThreatProtection: (v) =>
                              _setSecurityOption('threat_protection', v),
                          subscriptionActive: _subscriptionUrl != null,
                          onSubscription: _addSubscription,
                        ),
                        const SizedBox(height: 12),
                        _ConnectionLogCard(entries: _connectionLog),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PremiumStatsCard extends StatelessWidget {
  final bool connected;
  final DateTime? connectedAt;
  final int privacyScore;
  const _PremiumStatsCard({
    required this.connected,
    required this.connectedAt,
    required this.privacyScore,
  });

  String get session {
    if (!connected || connectedAt == null) return '00:00:00';
    final seconds = DateTime.now().difference(connectedAt!).inSeconds;
    final h = (seconds ~/ 3600).toString().padLeft(2, '0');
    final m = ((seconds % 3600) ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Expanded(child: _MetricTile('SESSION', session)),
          const SizedBox(width: 8),
          Expanded(child: _MetricTile('PUBLIC IP', connected ? 'Protected' : '— — —')),
          const SizedBox(width: 8),
          Expanded(child: _MetricTile('PRIVACY', '$privacyScore%')),
        ],
      );
}

class _MetricTile extends StatelessWidget {
  final String label;
  final String value;
  const _MetricTile(this.label, this.value);
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 11),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: const Color(0xFFE2E9F2)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label,
              style: const TextStyle(
                  color: Color(0xFF718096), fontSize: 9, fontWeight: FontWeight.w700)),
          const SizedBox(height: 5),
          Text(value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900)),
        ]),
      );
}

class _SecurityControlsCard extends StatelessWidget {
  final bool killSwitch;
  final bool splitTunneling;
  final bool threatProtection;
  final bool subscriptionActive;
  final ValueChanged<bool> onKillSwitch;
  final ValueChanged<bool> onSplitTunneling;
  final ValueChanged<bool> onThreatProtection;
  final VoidCallback onSubscription;
  const _SecurityControlsCard({
    required this.killSwitch,
    required this.splitTunneling,
    required this.threatProtection,
    required this.subscriptionActive,
    required this.onKillSwitch,
    required this.onSplitTunneling,
    required this.onThreatProtection,
    required this.onSubscription,
  });

  @override
  Widget build(BuildContext context) => _PanelCard(
        title: 'Privacy & automation',
        trailing: subscriptionActive ? 'Subscription active' : 'Power User',
        child: Column(children: [
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Kill switch', style: TextStyle(fontWeight: FontWeight.w700)),
            subtitle: const Text('Block traffic when the tunnel drops'),
            value: killSwitch,
            onChanged: onKillSwitch,
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Split tunneling', style: TextStyle(fontWeight: FontWeight.w700)),
            subtitle: const Text('Choose which apps use the VPN'),
            value: splitTunneling,
            onChanged: onSplitTunneling,
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Threat protection', style: TextStyle(fontWeight: FontWeight.w700)),
            subtitle: const Text('Block trackers and risky domains'),
            value: threatProtection,
            onChanged: onThreatProtection,
          ),
          const Divider(),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(
              onPressed: onSubscription,
              icon: const Icon(Icons.link_rounded),
              label: Text(subscriptionActive ? 'Edit subscription' : 'Add subscription'),
            ),
          ),
        ]),
      );
}

class _ConnectionLogCard extends StatelessWidget {
  final List<String> entries;
  const _ConnectionLogCard({required this.entries});
  @override
  Widget build(BuildContext context) => _PanelCard(
        title: 'Recent activity',
        trailing: entries.isEmpty ? 'No events' : '${entries.length} events',
        child: entries.isEmpty
            ? const Align(
                alignment: Alignment.centerLeft,
                child: Text('Connection diagnostics will appear here.',
                    style: TextStyle(color: Color(0xFF718096))))
            : Column(
                children: entries.take(4).map((entry) => ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.check_circle_outline,
                          color: Color(0xFF78B82F), size: 20),
                      title: Text(entry, style: const TextStyle(fontSize: 12)),
                      subtitle: const Text('Stored locally', style: TextStyle(fontSize: 10)),
                    )).toList(),
              ),
      );
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
  final String serverName;
  final String pingLabel;
  final int animationId;
  final VoidCallback onTap;
  const _ConnectCard({
    required this.connected,
    required this.connecting,
    required this.serverReady,
    required this.serverName,
    required this.pingLabel,
    required this.animationId,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 26, 22, 22),
      decoration: BoxDecoration(
        border: Border.all(
          color:
              connected ? const Color(0xFFB8E578) : const Color(0xFFDFE7F0),
        ),
        borderRadius: BorderRadius.circular(30),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Colors.white, Color(0xFFF4F8FD)],
        ),
        boxShadow: [
          const BoxShadow(
            color: Color(0x1821395A),
            blurRadius: 30,
            offset: Offset(0, 14),
          ),
          if (connected)
            const BoxShadow(
              color: Color(0x2EB7F34A),
              spreadRadius: 4,
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
          _BreathingGlow(
            color: connected
                ? const Color(0xFF91C92E)
                : !serverReady
                    ? const Color(0xFF9FB3C8)
                    : connecting
                        ? const Color(0xFF9AA7B8)
                        : const Color(0xFFE05252),
            child: SizedBox(
            width: 198,
            height: 198,
            child: Stack(
              alignment: Alignment.center,
              children: [
                GestureDetector(
                  onTap: serverReady ? onTap : null,
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
                            : connected
                                ? const [Color(0xFF35B853), Color(0xFF146C2E)]
                                : const [Color(0xFF25282D), Color(0xFF111316)],
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
                                  'Connecting…',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            )
                          : connecting
                              ? Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const CircularProgressIndicator(
                                      color: Color(0xFFD9FF72),
                                      strokeWidth: 3,
                                    ),
                                    const SizedBox(height: 12),
                                    const Text(
                                      'Connecting…',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                )
                              : Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      connected ? 'Connected ✓' : 'Connect',
                                      style: TextStyle(
                                        color: connected
                                            ? Colors.white
                                            : Colors.white,
                                        fontSize: 21,
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      connected
                                          ? 'Tap to disconnect'
                                          : 'Tap to connect',
                                      style: TextStyle(
                                        color: connected
                                            ? const Color(0xFFC5F391)
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
          ),
          const SizedBox(height: 18),
          _StatusBanner(
            connected: connected,
            connecting: connecting,
            serverReady: serverReady,
          ),
          const SizedBox(height: 14),
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

/// Small pill shown in the app bar: CONNECTED / CONNECTING / NOT CONNECTED.
class _HeaderStatus extends StatelessWidget {
  final bool connected;
  final bool connecting;
  const _HeaderStatus({required this.connected, required this.connecting});

  @override
  Widget build(BuildContext context) {
    final Color fg = connected
        ? const Color(0xFF356B0D)
        : connecting
            ? const Color(0xFF8A5F00)
            : const Color(0xFFA52A2A);
    final Color bg = connected
        ? const Color(0xFFEFFFE0)
        : connecting
            ? const Color(0xFFFFF6E0)
            : const Color(0xFFFFF0F0);
    final Color bd = connected
        ? const Color(0xFFB8E578)
        : connecting
            ? const Color(0xFFEFD9A8)
            : const Color(0xFFF0C6C6);
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: bg,
          border: Border.all(color: bd),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: fg, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                connected
                    ? 'CONNECTED'
                    : connecting
                        ? 'CONNECTING'
                        : 'NOT CONNECTED',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: fg,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w900,
                    letterSpacing: .5),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Pulsing dot used inside the status banner.
class _StatusDot extends StatefulWidget {
  final Color color;
  final Color glow;
  final Duration duration;
  const _StatusDot({
    required this.color,
    required this.glow,
    this.duration = const Duration(milliseconds: 1700),
  });

  @override
  State<_StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<_StatusDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  )..repeat(reverse: true);

  @override
  void didUpdateWidget(covariant _StatusDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.duration != widget.duration) {
      _controller.duration = widget.duration;
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) => Transform.scale(
        scale: 1 + _controller.value * .28,
        child: Container(
          width: 13,
          height: 13,
          decoration: BoxDecoration(
            color: widget.color,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(color: widget.glow, blurRadius: 10, spreadRadius: 3),
            ],
          ),
        ),
      ),
    );
  }
}

/// Soft breathing glow behind the connect button. Green while connected,
/// red while disconnected, amber while connecting — nothing rotates.
class _BreathingGlow extends StatefulWidget {
  final Color color;
  final Widget child;
  const _BreathingGlow({required this.color, required this.child});

  @override
  State<_BreathingGlow> createState() => _BreathingGlowState();
}

class _BreathingGlowState extends State<_BreathingGlow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final double t = _controller.value;
        return DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: widget.color.withOpacity(0.16 + 0.30 * t),
                blurRadius: 24 + 16 * t,
                spreadRadius: 4 + 6 * t,
              ),
            ],
          ),
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

/// Compact status pill shown right under the connect button. It always
/// states, in plain words, whether the tunnel is up or not.
class _StatusBanner extends StatelessWidget {
  final bool connected;
  final bool connecting;
  final bool serverReady;
  const _StatusBanner({
    required this.connected,
    required this.connecting,
    required this.serverReady,
  });

  @override
  Widget build(BuildContext context) {
    final bool busy = !connected && connecting && serverReady;
    final Color fg = connected
        ? const Color(0xFF356B0D)
        : busy
            ? const Color(0xFF8A5F00)
            : const Color(0xFFA52A2A);
    final Color bg = connected
        ? const Color(0xFFF0FFE0)
        : busy
            ? const Color(0xFFFFF8E6)
            : const Color(0xFFFFF3F3);
    final Color bd = connected
        ? const Color(0xFFB8E578)
        : busy
            ? const Color(0xFFEFD9A8)
            : const Color(0xFFF0C6C6);
    final Color dot = connected
        ? const Color(0xFF79D21A)
        : busy
            ? const Color(0xFFEDA32C)
            : const Color(0xFFE05252);
    final Color glow = connected
        ? const Color(0x3379D21A)
        : busy
            ? const Color(0x33EDA32C)
            : const Color(0x33E05252);
    final String title = connected
        ? 'CONNECTED'
        : busy
            ? 'CONNECTING…'
            : 'NOT CONNECTED';
    final String tag = connected ? 'ON' : busy ? '…' : 'OFF';
    final String sub = connected
        ? 'Secure tunnel active — traffic protected'
        : busy
            ? 'Establishing secure connection'
            : serverReady
                ? 'Your traffic is not protected'
                : 'Connecting…';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: bg,
        border: Border.all(color: bd),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _StatusDot(
            color: dot,
            glow: glow,
            duration: busy
                ? const Duration(milliseconds: 600)
                : const Duration(milliseconds: 1700),
          ),
          const SizedBox(width: 9),
          Text(
            title,
            style: TextStyle(
              color: fg,
              fontSize: 13,
              fontWeight: FontWeight.w900,
              letterSpacing: .6,
            ),
          ),
          const SizedBox(width: 7),
          Flexible(
            child: Text(
              sub,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: fg,
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              tag,
              style: TextStyle(
                color: fg,
                fontSize: 11,
                fontWeight: FontWeight.w900,
                letterSpacing: 1,
              ),
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
    const lime = Color(0xFFB7F34A);
    const limeDeep = Color(0xFF5FA80F);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        gradient: selected
            ? const LinearGradient(
                colors: [Color(0xFFF4FFE3), Color(0xFFE6FFC2)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight)
            : null,
        color: selected ? null : Colors.white,
        border: Border.all(
          color: selected ? lime : const Color(0xFFE8EDF4),
          width: selected ? 1.6 : 1,
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
              color: selected ? const Color(0x335FA80F) : const Color(0x0D21395A),
              blurRadius: selected ? 18 : 10,
              offset: const Offset(0, 5)),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          splashColor: lime.withValues(alpha: 0.25),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 11, 10, 11),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(colors: [
                      accent.withValues(alpha: 0.22),
                      accent.withValues(alpha: 0.08)
                    ]),
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: Icon(Icons.public, color: accent, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Flexible(
                          child: Text(server.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: Color(0xFF152238),
                                  fontWeight: FontWeight.w800,
                                  fontSize: 13.5)),
                        ),
                        if (rank == 1) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              color: lime,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: const Text('BEST',
                                style: TextStyle(
                                    color: Color(0xFF142015),
                                    fontWeight: FontWeight.w900,
                                    fontSize: 9,
                                    letterSpacing: .6)),
                          ),
                        ],
                      ]),
                      const SizedBox(height: 3),
                      Text(
                          server.health == 'offline'
                              ? 'Offline · unavailable'
                              : server.health == 'weak'
                                  ? 'Online · weak connection'
                                  : server.health == 'online'
                                      ? 'Online · encrypted gateway'
                                      : 'Checking availability…',
                          style: TextStyle(
                              color: server.health == 'offline'
                                  ? const Color(0xFFC45252)
                                  : const Color(0xFF8A96A8),
                              fontSize: 11)),
                    ],
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                  decoration: BoxDecoration(
                    color: pingColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(pingLabel,
                      style: TextStyle(
                          color: pingColor,
                          fontSize: 11.5,
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
                if (!(server.custom && onDelete != null))
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Icon(
                        selected
                            ? Icons.check_circle_rounded
                            : Icons.radio_button_unchecked,
                        size: 20,
                        color: selected ? limeDeep : const Color(0xFFCBD3DE)),
                  ),
              ],
            ),
          ),
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
  final bool autoConnect;
  final ValueChanged<bool> onAutoConnectChanged;
  const _AppDrawer({
    required this.autoConnect,
    required this.onAutoConnectChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Drawer(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
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
            ValueListenableBuilder<ThemeMode>(
              valueListenable: _themeMode,
              builder: (context, mode, _) => SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('Dark mode',
                    style: TextStyle(fontWeight: FontWeight.w700)),
                secondary: const Icon(Icons.dark_mode_outlined),
                value: mode == ThemeMode.dark,
                onChanged: (value) async {
                  _themeMode.value = value ? ThemeMode.dark : ThemeMode.light;
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setBool('dark_mode', value);
                },
              ),
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Auto-connect on network change',
                  style: TextStyle(fontWeight: FontWeight.w700)),
              secondary: const Icon(Icons.wifi_find_outlined),
              value: autoConnect,
              onChanged: onAutoConnectChanged,
            ),
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
