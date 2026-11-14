import 'dart:io';

import 'package:flutter/material.dart';

import 'capture_studio_screen.dart';
import 'phone_camera_screen.dart';
import 'receiver_screen.dart';

/// Recording page: **Camera** (phone as a pro camera -> PC) and **Studio** (screen capture and scenes,
/// OBS style). On Android the Camera tab opens the camera; on the PC, the receiver and the studio.
class RecordingTab extends StatelessWidget {
  const RecordingTab({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.phone_android), text: 'Câmera'),
              Tab(icon: Icon(Icons.screenshot_monitor), text: 'Estúdio'),
            ],
          ),
          Expanded(
            child: TabBarView(
              physics: const NeverScrollableScrollPhysics(),
              children: [
                Platform.isAndroid ? const _OpenCamera() : const ReceiverScreen(),
                Platform.isAndroid ? const _StudioOnPc() : const CaptureStudioScreen(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _OpenCamera extends StatelessWidget {
  const _OpenCamera();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.camera_alt_outlined, size: 56),
            const SizedBox(height: 12),
            const Text(
              'Câmera Pro: ISO, obturador, foco e branco manuais, até 4K/60 em HEVC e HLG 10-bit. '
              'Transmite ao PC pelo Wi-Fi ou USB e grava o original no aparelho.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: const Icon(Icons.videocam),
              label: const Text('Abrir câmera'),
              onPressed: () => _open(context),
            ),
          ],
        ),
      ),
    );
  }

  void _open(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const PhoneCameraScreen()));
  }
}

class _StudioOnPc extends StatelessWidget {
  const _StudioOnPc();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'O Estúdio de captura roda no PC (tela, cenas, mixer, desenho e gravação em NVENC). '
          'Daqui, use a aba Câmera para mandar a imagem do celular para ele.',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
