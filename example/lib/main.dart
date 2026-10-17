import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:store_asset_packs/store_asset_packs.dart';

/// The packs declared under `store_asset_packs:` in this app's pubspec.yaml.
const packs = ['fast_pack', 'ondemand_pack'];

void main() => runApp(const MaterialApp(home: PacksPage()));

class PacksPage extends StatefulWidget {
  const PacksPage({super.key});

  @override
  State<PacksPage> createState() => _PacksPageState();
}

class _PacksPageState extends State<PacksPage> {
  final _states = <String, AssetPackState>{};
  final _paths = <String, String?>{};
  final _log = <String>[];
  StreamSubscription<AssetPackState>? _updates;

  @override
  void initState() {
    super.initState();
    _updates = StoreAssetPacks.updates.listen(_onUpdate, onError: _onError);
    _refresh();
  }

  @override
  void dispose() {
    _updates?.cancel();
    super.dispose();
  }

  void _say(String line) {
    debugPrint('store_asset_packs example: $line');
    setState(() => _log.insert(0, line));
  }

  void _onError(Object error) => _say('error: $error');

  Future<void> _onUpdate(AssetPackState state) async {
    _say('update $state');
    setState(() => _states[state.name] = state);
    if (state.status == AssetPackStatus.completed) await _loadPath(state.name);
    if (state.status == AssetPackStatus.waitingForWifi ||
        state.status == AssetPackStatus.requiresUserConfirmation) {
      final ok = await StoreAssetPacks.showCellularDataConfirmation();
      _say('confirmation: $ok');
    }
  }

  Future<void> _refresh() async {
    try {
      final states = await StoreAssetPacks.getStates(packs);
      setState(() => _states.addAll(states));
      _say('states ${states.values.join(', ')}');
      for (final s in states.values) {
        if (s.isAvailable) await _loadPath(s.name);
      }
    } catch (e) {
      _onError(e);
    }
  }

  Future<void> _loadPath(String pack) async {
    final path = await StoreAssetPacks.getPackPath(pack);
    _say('path $pack: $path');
    setState(() => _paths[pack] = path);
  }

  Future<void> _fetch(String pack) async {
    try {
      await StoreAssetPacks.fetch([pack]);
      _say('fetch $pack requested');
    } catch (e) {
      _onError(e);
    }
  }

  Future<void> _release(String pack) async {
    await StoreAssetPacks.release(pack);
    setState(() => _paths.remove(pack));
    _say('released $pack');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('store_asset_packs'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _refresh),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          for (final pack in packs) _packCard(pack),
          const SizedBox(height: 16),
          Text('Log', style: Theme.of(context).textTheme.titleMedium),
          for (final line in _log.take(40))
            Text(line, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }

  Widget _packCard(String pack) {
    final state = _states[pack];
    final path = _paths[pack];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(pack, style: Theme.of(context).textTheme.titleMedium),
            Text(
              state == null
                  ? 'state unknown'
                  : '${state.status.name}  ${state.bytesDownloaded}/${state.totalBytes} bytes'
                        '${state.errorCode == null ? '' : '  error ${state.errorCode}'}',
              key: Key('status_$pack'),
            ),
            LinearProgressIndicator(value: state?.progress ?? 0),
            if (path != null) ...[
              Text(path, style: const TextStyle(fontSize: 11)),
              Row(
                children: [
                  for (final file in ['image.png', 'nested/image.png'])
                    Padding(
                      padding: const EdgeInsets.all(4),
                      child: Image.file(
                        File('$path/$file'),
                        width: 64,
                        height: 64,
                        errorBuilder: (_, e, _) => Text('missing $file'),
                      ),
                    ),
                ],
              ),
            ],
            Row(
              children: [
                TextButton(
                  key: Key('fetch_$pack'),
                  onPressed: () => _fetch(pack),
                  child: const Text('Fetch'),
                ),
                TextButton(
                  onPressed: () => _loadPath(pack),
                  child: const Text('Path'),
                ),
                TextButton(
                  onPressed: () => _release(pack),
                  child: const Text('Release'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
