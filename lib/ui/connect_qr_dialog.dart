import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:notebook_core/notebook_core.dart';
import 'package:qr/qr.dart';

import '../state/notebook_controller.dart';
import 'peer_presence_bar.dart';

Future<void> showConnectQrDialog(
  BuildContext context,
  NotebookController controller,
) {
  controller.fetchServerInfo();
  return showDialog<void>(
    context: context,
    builder: (ctx) => _ConnectQrDialog(controller: controller),
  );
}

class _ConnectQrDialog extends StatefulWidget {
  const _ConnectQrDialog({required this.controller});

  final NotebookController controller;

  @override
  State<_ConnectQrDialog> createState() => _ConnectQrDialogState();
}

class _ConnectQrDialogState extends State<_ConnectQrDialog> {
  late final TextEditingController _wsController;
  late final TextEditingController _roomController;
  late final TextEditingController _nameController;
  late final TextEditingController _hotspotSsidController;
  late final TextEditingController _hotspotPassController;
  int _selectedUrlIdx = 0;
  bool _qrModeApk = false;
  bool _startedDiscoveryHere = false;

  @override
  void initState() {
    super.initState();
    _wsController = TextEditingController(text: widget.controller.wsUrl);
    _roomController = TextEditingController(text: widget.controller.roomId);
    _nameController =
        TextEditingController(text: widget.controller.displayName);
    _hotspotSsidController =
        TextEditingController(text: widget.controller.manualHotspotSsid);
    _hotspotPassController =
        TextEditingController(text: widget.controller.manualHotspotPassword);

    if (widget.controller.autoConnect &&
        widget.controller.platform.canDiscoverNearby &&
        !widget.controller.isDiscoveringNearby) {
      _startedDiscoveryHere = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(widget.controller.startDiscovery());
        }
      });
    }
  }

  @override
  void dispose() {
    if (_startedDiscoveryHere) {
      unawaited(widget.controller.stopDiscovery());
    }
    _wsController.dispose();
    _roomController.dispose();
    _nameController.dispose();
    _hotspotSsidController.dispose();
    _hotspotPassController.dispose();
    super.dispose();
  }

  Future<void> _scanQrAndApply() async {
    final c = widget.controller;
    final raw = await c.platform.scanQrCode();
    if (raw == null || !mounted) return;
    final parsed = await c.applyScannedQr(raw);
    if (!mounted) return;
    if (parsed != null) {
      _wsController.text = c.wsUrl;
      _roomController.text = c.roomId;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          parsed != null
              ? '已识别并连接 ${parsed.wsUrl} (房间: ${c.roomId})'
              : '二维码不包含有效的 SyncCanvas 连接地址',
        ),
      ),
    );
  }

  Future<void> _handleJoinBeacon(NearbyBoardBeacon beacon) async {
    final c = widget.controller;
    final outcome = await c.joinNearbyBoard(beacon);
    if (!mounted) return;

    if (outcome.connected) {
      _wsController.text = c.wsUrl;
      _roomController.text = c.roomId;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已通过自组网接入「${beacon.hostName}」(${c.wsUrl})'),
        ),
      );
      return;
    }

    if (outcome.needsManualWifiJoin && beacon.hasHotspotCredentials) {
      await _showManualWifiJoinGuide(beacon);
      return;
    }

    if (outcome.error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(outcome.error!)),
      );
    }
  }

  Future<void> _showManualWifiJoinGuide(NearbyBoardBeacon beacon) async {
    final ssid = beacon.hotspotSsid ?? '';
    final password = beacon.hotspotPassword ?? '';
    final retry = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('已通过蓝牙获取热点凭证'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '请前往系统 Wi-Fi 设置连接到「${beacon.hostName}」开启的共享热点，然后点击下方立即连接：',
              style: const TextStyle(fontSize: 13, height: 1.45),
            ),
            const SizedBox(height: 12),
            _CopyUrlRow(
              label: 'Wi-Fi 名称',
              value: ssid,
              onCopy: () => _copyText(ssid, 'Wi-Fi 名称'),
            ),
            if (password.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              _CopyUrlRow(
                label: 'Wi-Fi 密码',
                value: password,
                onCopy: () => _copyText(password, 'Wi-Fi 密码'),
              ),
            ],
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('稍后'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(ctx).pop(true),
            icon: const Icon(Icons.wifi_find_rounded, size: 18),
            label: const Text('我已连上热点，立即同步'),
          ),
        ],
      ),
    );
    if (retry == true && mounted) {
      await _handleJoinBeacon(beacon);
    }
  }

  Future<void> _copyText(String value, String label) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已复制 $label'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _showImportDialog() async {
    final jsonCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入备份 (.nbk.json)'),
        content: SizedBox(
          width: 440,
          child: TextField(
            controller: jsonCtrl,
            maxLines: 10,
            decoration: const InputDecoration(
              hintText: '粘贴导出的 JSON 内容，系统将通过 CRDT 无损合并到当前房间...',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('合并导入'),
          ),
        ],
      ),
    );
    if (ok == true && jsonCtrl.text.trim().isNotEmpty) {
      final success =
          await widget.controller.importRoomJson(jsonCtrl.text.trim());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(success ? '已通过 CRDT 合并导入画板数据' : 'JSON 格式无效'),
          ),
        );
      }
    }
    jsonCtrl.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final c = widget.controller;
        final httpUrls = c.lanHttpUrls;
        final wsUrls = c.lanWsUrls;
        final apkUrls = c.lanApkUrls;
        final showApkQr = _qrModeApk && apkUrls.isNotEmpty;
        final connectUrl = httpUrls.isNotEmpty
            ? httpUrls[_selectedUrlIdx.clamp(0, httpUrls.length - 1)]
            : 'http://127.0.0.1:8787/?room=${Uri.encodeQueryComponent(c.roomId)}';
        final apkUrl = showApkQr
            ? apkUrls[_selectedUrlIdx.clamp(0, apkUrls.length - 1)]
            : null;
        final activeQrUrl = apkUrl ?? connectUrl;

        return AlertDialog(
          titlePadding: const EdgeInsets.fromLTRB(20, 18, 12, 8),
          contentPadding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
          title: Row(
            children: <Widget>[
              const Icon(Icons.qr_code_2_rounded, color: Color(0xFF4F46E5)),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  '三端连接与同步中心',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
              ),
              SyncStatusChip(controller: c, onTap: c.connect),
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  // QR Code + LAN Instructions
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                    ),
                    child: LayoutBuilder(
                      builder: (context, box) {
                        final narrow = box.maxWidth < 430;
                        final qrWidget = Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0xFFE2E8F0)),
                          ),
                          child: _QrCodeView(data: activeQrUrl, size: 152),
                        );
                        final infoWidget = Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              showApkQr
                                  ? 'Android 扫码下载原生 APK 安装包'
                                  : '手机 / iPad 扫码即刻加入同一画板',
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF0F172A),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              showApkQr
                                  ? '同一 Wi-Fi 下用 Android 浏览器扫码即可下载安装包（安装后可用下方「摄像头扫码秒连」直连画板）：'
                                  : '确保三台设备在同一 Wi-Fi 下，使用浏览器或原生客户端打开下方地址即可秒级同屏协同：',
                              style: const TextStyle(
                                fontSize: 12,
                                height: 1.4,
                                color: Color(0xFF475569),
                              ),
                            ),
                            if (apkUrls.isNotEmpty) ...<Widget>[
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 6,
                                runSpacing: 4,
                                children: <Widget>[
                                  ChoiceChip(
                                    label: const Text('扫码同屏连接',
                                        style: TextStyle(fontSize: 11.5)),
                                    selected: !showApkQr,
                                    visualDensity: VisualDensity.compact,
                                    onSelected: (_) =>
                                        setState(() => _qrModeApk = false),
                                  ),
                                  ChoiceChip(
                                    label: const Text('扫码下载 Android APK',
                                        style: TextStyle(fontSize: 11.5)),
                                    selected: showApkQr,
                                    visualDensity: VisualDensity.compact,
                                    onSelected: (_) =>
                                        setState(() => _qrModeApk = true),
                                  ),
                                ],
                              ),
                            ],
                            if (c.platform.canScanQrCode) ...<Widget>[
                              const SizedBox(height: 8),
                              FilledButton.icon(
                                onPressed: _scanQrAndApply,
                                icon: const Icon(Icons.qr_code_scanner_rounded,
                                    size: 18),
                                label: const Text('摄像头扫码秒连'),
                              ),
                            ],
                            const SizedBox(height: 8),
                            if (httpUrls.length > 1)
                              Wrap(
                                spacing: 6,
                                runSpacing: 4,
                                children: <Widget>[
                                  for (var i = 0; i < httpUrls.length; i++)
                                    ChoiceChip(
                                      label: Text(
                                        Uri.parse(httpUrls[i]).host,
                                        style: const TextStyle(fontSize: 11),
                                      ),
                                      selected: _selectedUrlIdx == i,
                                      visualDensity: VisualDensity.compact,
                                      onSelected: (_) =>
                                          setState(() => _selectedUrlIdx = i),
                                    ),
                                ],
                              ),
                            const SizedBox(height: 6),
                            _CopyUrlRow(
                              label: showApkQr ? 'APK 下载' : 'Web / PWA',
                              value: activeQrUrl,
                              onCopy: () => _copyText(
                                activeQrUrl,
                                showApkQr ? 'APK 下载地址' : 'Web 地址',
                              ),
                            ),
                            if (!showApkQr && wsUrls.isNotEmpty) ...<Widget>[
                              const SizedBox(height: 6),
                              _CopyUrlRow(
                                label: 'App WS',
                                value: wsUrls[_selectedUrlIdx.clamp(
                                    0, wsUrls.length - 1)],
                                onCopy: () => _copyText(
                                  wsUrls[_selectedUrlIdx.clamp(
                                      0, wsUrls.length - 1)],
                                  'WebSocket 地址',
                                ),
                              ),
                            ],
                          ],
                        );

                        if (narrow) {
                          return Column(
                            children: <Widget>[
                              qrWidget,
                              const SizedBox(height: 12),
                              infoWidget,
                            ],
                          );
                        }
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            qrWidget,
                            const SizedBox(width: 14),
                            Expanded(child: infoWidget),
                          ],
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 14),

                  if (c.platform.canHostServer) ...<Widget>[
                    _buildSelfHostCard(c),
                    const SizedBox(height: 14),
                  ],

                  if (c.platform.canDiscoverNearby) ...<Widget>[
                    _buildNearbyRadarCard(c),
                    const SizedBox(height: 14),
                  ],

                  // Server & Room configuration
                  const Text(
                    '房间与同步服务配置',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF0F172A),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: <Widget>[
                      Expanded(
                        flex: 2,
                        child: TextField(
                          controller: _wsController,
                          style: const TextStyle(fontSize: 13),
                          decoration: const InputDecoration(
                            labelText: 'WebSocket 服务地址',
                            hintText: 'ws://192.168.1.x:8787/ws',
                            isDense: true,
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _roomController,
                          style: const TextStyle(fontSize: 13),
                          decoration: const InputDecoration(
                            labelText: '房间号 Room',
                            hintText: 'default',
                            isDense: true,
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: TextField(
                          controller: _nameController,
                          style: const TextStyle(fontSize: 13),
                          decoration: const InputDecoration(
                            labelText: '当前设备名称',
                            isDense: true,
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      for (final color in NotebookController.inkPalette.take(5))
                        GestureDetector(
                          onTap: () => c.updateIdentity(
                            avatarColorValue: color.toARGB32(),
                          ),
                          child: Container(
                            margin: const EdgeInsets.only(left: 5),
                            width: 22,
                            height: 22,
                            decoration: BoxDecoration(
                              color: color,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: c.avatarColorValue == color.toARGB32()
                                    ? const Color(0xFF0F172A)
                                    : Colors.transparent,
                                width: 2.2,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      FilledButton.icon(
                        onPressed: () {
                          c.updateIdentity(displayName: _nameController.text);
                          c.configureConnection(
                            wsUrl: _wsController.text,
                            roomId: _roomController.text,
                          );
                        },
                        icon: const Icon(Icons.sync_rounded, size: 18),
                        label: const Text('应用并连接'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () async {
                          final saved = await c.saveExportToDevice();
                          await Clipboard.setData(
                            ClipboardData(text: c.exportRoomJson()),
                          );
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  saved != null
                                      ? '已导出 $saved 并复制 JSON 到剪贴板'
                                      : '已复制 .nbk.json 到剪贴板',
                                ),
                              ),
                            );
                          }
                        },
                        icon: const Icon(Icons.download_outlined, size: 17),
                        label: const Text('导出'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _showImportDialog,
                        icon: const Icon(Icons.upload_outlined, size: 17),
                        label: const Text('导入'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),

                  // Online Peers List
                  const Text(
                    '在线协同设备',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF0F172A),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: <Widget>[
                      Chip(
                        avatar: Icon(
                          iconForFormFactor(c.formFactor),
                          size: 16,
                          color: Color(c.avatarColorValue),
                        ),
                        label: Text(
                          '${c.displayName} (本机 · ${c.formFactor.label})',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                      for (final peer in c.remotePeers)
                        ActionChip(
                          avatar: Icon(
                            iconForFormFactor(peer.formFactor),
                            size: 16,
                            color: Color(peer.colorValue),
                          ),
                          label: Text(
                            '${peer.displayName} (${peer.formFactor.label})',
                            style: const TextStyle(fontSize: 12),
                          ),
                          onPressed: () {
                            c.jumpToPeer(peer.peerId);
                            Navigator.of(context).pop();
                          },
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSelfHostCard(NotebookController c) {
    final hotspot = c.activeHotspot;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.isHostingLocalServer
            ? const Color(0xFFF0FDF4)
            : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: c.isHostingLocalServer
              ? const Color(0xFF86EFAC)
              : const Color(0xFFE2E8F0),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                Icons.wifi_tethering_rounded,
                size: 18,
                color: c.isHostingLocalServer
                    ? const Color(0xFF16A34A)
                    : const Color(0xFF4F46E5),
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  '随身房主模式（无路由器自组网）',
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF0F172A),
                  ),
                ),
              ),
              if (c.isHostingLocalServer)
                FilledButton.tonal(
                  onPressed: () async {
                    await c.stopLocalHostMode();
                  },
                  child: const Text('关闭房主', style: TextStyle(fontSize: 12)),
                )
              else
                FilledButton(
                  onPressed: () async {
                    final ok = await c.startLocalHostMode(
                      requestAndroidHotspot: c.platform.canManageHotspot,
                    );
                    if (ok && mounted) {
                      _wsController.text = c.wsUrl;
                      _roomController.text = c.roomId;
                    }
                  },
                  child: const Text('本机当房主', style: TextStyle(fontSize: 12)),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            c.isHostingLocalServer
                ? '已在端口 ${c.hostedServerPort ?? 8787} 开启内置同步服务端，并通过 BLE 蓝牙 + 局域网广播等待附近设备加入。'
                : '无电脑 / 无 Wi-Fi 路由器时，可直接让当前设备作为画板房主，通过蓝牙或个人热点带动手机、iPad 与 Mac 协同。',
            style: const TextStyle(
              fontSize: 12,
              height: 1.4,
              color: Color(0xFF475569),
            ),
          ),
          if (c.isHostingLocalServer) ...<Widget>[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                if (c.platform.canManageHotspot)
                  OutlinedButton.icon(
                    onPressed: () async {
                      await c.toggleAndroidLocalHotspot();
                    },
                    icon: Icon(
                      hotspot != null
                          ? Icons.portable_wifi_off_outlined
                          : Icons.wifi_tethering_error_rounded,
                      size: 16,
                    ),
                    label: Text(
                      hotspot != null ? '关闭本地直连热点' : '开启本地直连热点（蓝牙自动配密）',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                if (c.platform.canManageHotspot)
                  OutlinedButton.icon(
                    onPressed: () => c.platform.openSystemHotspotSettings(),
                    icon: const Icon(Icons.settings_input_antenna, size: 16),
                    label: const Text('系统个人热点设置', style: TextStyle(fontSize: 12)),
                  ),
              ],
            ),
            if (hotspot != null) ...<Widget>[
              const SizedBox(height: 8),
              _CopyUrlRow(
                label: '热点名称',
                value: hotspot.ssid,
                onCopy: () => _copyText(hotspot.ssid, '热点名称'),
              ),
              if (hotspot.password.isNotEmpty) ...<Widget>[
                const SizedBox(height: 6),
                _CopyUrlRow(
                  label: '热点密码',
                  value: hotspot.password,
                  onCopy: () => _copyText(hotspot.password, '热点密码'),
                ),
              ],
            ],
            const SizedBox(height: 10),
            const Text(
              '若使用手机系统个人热点，可填写名称与密码通过 BLE 蓝牙广播给 iPad / Android：',
              style: TextStyle(fontSize: 11.5, color: Color(0xFF64748B)),
            ),
            const SizedBox(height: 6),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _hotspotSsidController,
                    style: const TextStyle(fontSize: 12),
                    decoration: const InputDecoration(
                      labelText: '热点名称 (可选)',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: TextField(
                    controller: _hotspotPassController,
                    style: const TextStyle(fontSize: 12),
                    decoration: const InputDecoration(
                      labelText: '热点密码 (可选)',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                FilledButton.tonal(
                  onPressed: () => c.setManualHotspotHint(
                    _hotspotSsidController.text,
                    _hotspotPassController.text,
                  ),
                  child: const Text('广播', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ],
          if (c.hostBroadcastNotice != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              c.hostBroadcastNotice!,
              style: const TextStyle(
                fontSize: 11.5,
                color: Color(0xFFB45309),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildNearbyRadarCard(NotebookController c) {
    final boards = c.nearbyBoards;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFEEF2FF).withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFC7D2FE)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(
                Icons.bluetooth_searching_rounded,
                size: 18,
                color: Color(0xFF4F46E5),
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  '附近画板雷达（BLE 蓝牙 + 局域网自动发现）',
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF0F172A),
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: () async {
                  if (c.isDiscoveringNearby) {
                    await c.stopDiscovery();
                  } else {
                    await c.startDiscovery();
                  }
                },
                icon: Icon(
                  c.isDiscoveringNearby
                      ? Icons.pause_circle_outline
                      : Icons.radar_rounded,
                  size: 16,
                ),
                label: Text(
                  c.isDiscoveringNearby ? '暂停雷达' : '开始扫描',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
          if (c.discoveryNotice != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                c.discoveryNotice!,
                style: const TextStyle(fontSize: 11.5, color: Color(0xFFB45309)),
              ),
            ),
          if (boards.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                c.isDiscoveringNearby
                    ? '正在搜索附近的 SyncCanvas 蓝牙信标与同局域网/热点房主...'
                    : '点击「开始扫描」自动搜寻附近的共享画板房主',
                style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
              ),
            )
          else
            Column(
              children: <Widget>[
                for (final beacon in boards)
                  Container(
                    margin: const EdgeInsets.only(top: 6),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                    ),
                    child: Row(
                      children: <Widget>[
                        Icon(
                          iconForFormFactor(beacon.formFactor),
                          size: 18,
                          color: const Color(0xFF4F46E5),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                beacon.hostName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF0F172A),
                                ),
                              ),
                              Text(
                                '房间: ${beacon.roomId} · ${beacon.transport.label}'
                                '${beacon.hasHotspotCredentials ? ' · 含热点直连' : ''}'
                                '${beacon.rssi != null ? ' (${beacon.rssi} dBm)' : ''}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Color(0xFF64748B),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton.tonal(
                          onPressed: c.isJoiningNearby
                              ? null
                              : () => _handleJoinBeacon(beacon),
                          child: Text(
                            c.isJoiningNearby ? '接入中' : '秒连加入',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _CopyUrlRow extends StatelessWidget {
  const _CopyUrlRow({
    required this.label,
    required this.value,
    required this.onCopy,
  });

  final String label;
  final String value;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Row(
        children: <Widget>[
          Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: Color(0xFF4F46E5),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: SelectableText(
              value,
              maxLines: 1,
              style: const TextStyle(
                fontSize: 11.5,
                fontFamily: 'monospace',
                color: Color(0xFF1E293B),
              ),
            ),
          ),
          InkWell(
            onTap: onCopy,
            child: const Padding(
              padding: EdgeInsets.all(3),
              child: Icon(Icons.copy_rounded, size: 15, color: Color(0xFF64748B)),
            ),
          ),
        ],
      ),
    );
  }
}

class _QrCodeView extends StatelessWidget {
  const _QrCodeView({required this.data, required this.size});

  final String data;
  final double size;

  @override
  Widget build(BuildContext context) {
    final qrCode = QrCode.fromData(
      data: data,
      errorCorrectLevel: QrErrorCorrectLevel.M,
    );
    final qrImage = QrImage(qrCode);

    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _QrMatrixPainter(qrImage),
      ),
    );
  }
}

class _QrMatrixPainter extends CustomPainter {
  const _QrMatrixPainter(this.qrImage);

  final QrImage qrImage;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    final count = qrImage.moduleCount;
    final cell = size.width / count;
    final paint = Paint()
      ..color = const Color(0xFF0F172A)
      ..style = PaintingStyle.fill;

    for (var r = 0; r < count; r++) {
      for (var c = 0; c < count; c++) {
        if (qrImage.isDark(r, c)) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(
                c * cell + cell * 0.04,
                r * cell + cell * 0.04,
                cell * 0.92,
                cell * 0.92,
              ),
              Radius.circular(cell * 0.2),
            ),
            paint,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _QrMatrixPainter oldDelegate) {
    return oldDelegate.qrImage != qrImage;
  }
}
