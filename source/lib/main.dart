import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_vless/flutter_vless.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

void main() => runApp(const ManotoVpnApp());

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
  bool _busy = false;
  bool _showAllServers = false;

  bool get _isConnected => (_status?.state ?? '').toUpperCase() == 'CONNECTED';
  bool get _isConnecting =>
      (_status?.state ?? '').toUpperCase().contains('CONNECTING');

  @override
  void initState() {
    super.initState();
    _vless = FlutterVless(
      onStatusChanged: (status) {
        if (mounted) setState(() => _status = status);
      },
    );
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await _vless.initializeVless();
    _initialized = true;
    await _loadServers();
  }

  Future<void> _loadServers() async {
    final raw =
        await rootBundle.loadString('assets/configs/default_servers.json');
    final defaults = (jsonDecode(raw) as List)
        .map((e) => Server(
              name: e['name'],
              protocol: e['protocol'],
              uri: e['uri'],
            ))
        .toList();

    final prefs = await SharedPreferences.getInstance();
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

    final previousUri = _selectedServer?.uri;

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

    _testPings(_servers);
    _testPings(_customServers);
  }

  Future<void> _testPings(List<Server> list) async {
    await Future.wait(list.map((s) async {
      try {
        final parsed = FlutterVless.parse(s.uri);
        final delay = await _vless.getServerDelay(
          config: parsed.getFullConfiguration(),
          url: 'https://www.gstatic.com/generate_204',
        );
        if (mounted) setState(() => s.ping = delay);
      } catch (_) {
        if (mounted) setState(() => s.ping = -1);
      }
    }));
    if (mounted) {
      setState(() {
        _servers.sort((a, b) => _rank(a.ping).compareTo(_rank(b.ping)));
      });
    }
  }

  int _rank(int? p) {
    if (p == null) return 999998;
    if (p < 0) return 999999;
    return p;
  }

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

    final displayPing = (p / 10).round();
    return 'PING $displayPing';
  }

  Future<void> _toggleConnection() async {
    if (_busy || !_initialized) return;
    setState(() => _busy = true);
    try {
      if (_isConnected || _isConnecting) {
        await _vless.stopVless();
      } else {
        final server = _selectedServer;

        if (server == null) {
          _showSnack('No server selected');
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
        _showAllServers ? rankedServers : rankedServers.take(6).toList();

    return Scaffold(
      endDrawer: const _AppDrawer(),
      body: Container(
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
                        onPressed: () => Scaffold.of(context).openEndDrawer(),
                        icon: const Icon(Icons.menu_rounded),
                        style: IconButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: const Color(0xFF152238),
                          side: const BorderSide(color: Color(0xFFE4EAF2)),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.all(Radius.circular(12)),
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
                      serverName: selectedServer?.name ?? 'Loading...',
                      pingLabel: _pingLabel(selectedServer?.ping),
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
                              pingColor: index < 5
                                  ? const Color(0xFF78B82F)
                                  : _pingColor(server.ping),
                              pingLabel: _pingLabel(server.ping),
                              accent: _accentFor(server.name),
                              rank: index < 5 ? index + 1 : null,
                              onTap: () =>
                                  setState(() => _selectedServer = server),
                            );
                          }),
                          if (rankedServers.length > 10)
                            TextButton.icon(
                              onPressed: () => setState(() {
                                _showAllServers = !_showAllServers;
                              }),
                              icon: Icon(_showAllServers
                                  ? Icons.keyboard_arrow_up
                                  : Icons.keyboard_arrow_down),
                              label: Text(_showAllServers
                                  ? 'Show less'
                                  : 'Show ${rankedServers.length - 6} more'),
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
                                border:
                                    Border.all(color: const Color(0xFFE4EAF2)),
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
                                selected: _selectedServer?.uri == server.uri,
                                pingColor: _pingColor(server.ping),
                                pingLabel: _pingLabel(server.ping),
                                accent: _accentFor(server.name),
                                onTap: () =>
                                    setState(() => _selectedServer = server),
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
  final String serverName;
  final String pingLabel;
  final VoidCallback onTap;
  const _ConnectCard({
    required this.connected,
    required this.connecting,
    required this.serverName,
    required this.pingLabel,
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
                  onTap: onTap,
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
                        colors: connected
                            ? const [Color(0xFFD9FF72), Color(0xFFA7E832)]
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
                      child: connecting
                          ? const CircularProgressIndicator(
                              color: Color(0xFF152238))
                          : Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  connected ? 'Disconnect' : 'Connect',
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
    return Container(
      margin: const EdgeInsets.only(bottom: 9),
      decoration: BoxDecoration(
        color: selected ? const Color(0xFFF2FFF9) : Colors.white,
        border: Border.all(
          color: selected ? const Color(0xFF83D9B5) : const Color(0xFFE4EAF2),
        ),
        borderRadius: BorderRadius.circular(17),
        boxShadow: const [
          BoxShadow(
              color: Color(0x0A21395A), blurRadius: 10, offset: Offset(0, 4)),
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
              child: Icon(Icons.public, color: accent, size: 18),
            ),
          ],
        ),
        title: Text(server.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
        subtitle: Text(server.protocol,
            style: const TextStyle(color: Color(0xFF8A96A8), fontSize: 11)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(pingLabel,
                style: TextStyle(
                    color: pingColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                    fontFeatures: const [FontFeature.tabularFigures()])),
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
                  'Manoto VPN — VLESS and Trojan client. Version 1.0.0.'),
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
