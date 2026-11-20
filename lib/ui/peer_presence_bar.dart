import 'package:flutter/material.dart';
import 'package:notebook_core/notebook_core.dart';

import '../state/notebook_controller.dart';

IconData iconForFormFactor(DeviceFormFactor formFactor) {
  switch (formFactor) {
    case DeviceFormFactor.desktop:
      return Icons.laptop_mac_rounded;
    case DeviceFormFactor.tablet:
      return Icons.tablet_mac_rounded;
    case DeviceFormFactor.phone:
      return Icons.smartphone_rounded;
    case DeviceFormFactor.web:
      return Icons.language_rounded;
  }
}

class SyncStatusChip extends StatelessWidget {
  const SyncStatusChip({
    super.key,
    required this.controller,
    required this.onTap,
    this.compact = false,
  });

  final NotebookController controller;
  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    Color dotColor;
    switch (controller.connectionState) {
      case SyncConnectionState.connected:
        dotColor = const Color(0xFF16A34A);
        break;
      case SyncConnectionState.connecting:
        dotColor = const Color(0xFFD97706);
        break;
      case SyncConnectionState.offline:
      case SyncConnectionState.error:
        dotColor = const Color(0xFF64748B);
        break;
    }

    final pending = controller.pendingOpCount;
    final label = pending > 0
        ? '${controller.connectionState.label} · 待发 $pending'
        : controller.connectionState.label;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 8 : 10,
          vertical: 5,
        ),
        decoration: BoxDecoration(
          color: dotColor.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: dotColor.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: dotColor,
                shape: BoxShape.circle,
              ),
            ),
            if (!compact) ...<Widget>[
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: dotColor,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class PeerPresenceBar extends StatelessWidget {
  const PeerPresenceBar({
    super.key,
    required this.controller,
    this.maxVisible = 4,
  });

  final NotebookController controller;
  final int maxVisible;

  @override
  Widget build(BuildContext context) {
    final peers = controller.remotePeers;
    if (peers.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: const Color(0xFFF1F5F9),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              iconForFormFactor(controller.formFactor),
              size: 14,
              color: Color(controller.avatarColorValue),
            ),
            const SizedBox(width: 5),
            const Text(
              '当前仅本机在线',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
                color: Color(0xFF475569),
              ),
            ),
          ],
        ),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (final peer in peers.take(maxVisible))
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: _PeerPill(
              peer: peer,
              isFollowing: controller.followingPeerId == peer.peerId,
              onTap: () => controller.toggleFollowPeer(peer.peerId),
            ),
          ),
        if (peers.length > maxVisible)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFFE2E8F0),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              '+${peers.length - maxVisible}',
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Color(0xFF334155),
              ),
            ),
          ),
      ],
    );
  }
}

class _PeerPill extends StatelessWidget {
  const _PeerPill({
    required this.peer,
    required this.isFollowing,
    required this.onTap,
  });

  final PeerPresence peer;
  final bool isFollowing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = Color(peer.colorValue);
    return Tooltip(
      message: isFollowing
          ? '正在跟随 ${peer.displayName} 的视角（点击取消）'
          : '点击跳转并跟随 ${peer.displayName} (${peer.formFactor.label})',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(
            color: isFollowing
                ? color.withValues(alpha: 0.16)
                : Colors.white,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: isFollowing ? color : const Color(0xFFE2E8F0),
              width: isFollowing ? 1.6 : 1.0,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                iconForFormFactor(peer.formFactor),
                size: 14,
                color: color,
              ),
              const SizedBox(width: 5),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 92),
                child: Text(
                  isFollowing ? '跟随: ${peer.displayName}' : peer.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: isFollowing ? color : const Color(0xFF1E293B),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
