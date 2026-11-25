import 'package:flutter/material.dart';
import 'package:kovalink/src/services/gateway_controller.dart';

class StatusPill extends StatelessWidget {
  const StatusPill({required this.mode, super.key});

  final GatewayMode mode;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (mode) {
      GatewayMode.demo => ('데모', const Color(0xFF72A7FF)),
      GatewayMode.connecting => ('연결 중', const Color(0xFFFFC857)),
      GatewayMode.live => ('연결됨', const Color(0xFF58F2C2)),
      GatewayMode.disconnected => ('연결 안 됨', const Color(0xFF8E9DA9)),
      GatewayMode.error => ('연결 오류', const Color(0xFFFF6B72)),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.4,
            ),
          ),
        ],
      ),
    );
  }
}
