import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Opens the camera and returns the first barcode it reads.
/// In continuous mode it calls [onCode] for every new code and stays open (fast POS scanning).
class ScannerScreen extends StatefulWidget {
  final bool continuous;
  final void Function(String code)? onCode;
  const ScannerScreen({super.key, this.continuous = false, this.onCode});

  static Future<String?> scanOnce(BuildContext context) =>
      Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const ScannerScreen()));

  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> {
  final _controller = MobileScannerController(detectionSpeed: DetectionSpeed.normal);
  String? _last;
  DateTime _lastAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _count = 0;
  bool _done = false;

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    final code = capture.barcodes.map((b) => b.rawValue).whereType<String>().firstOrNull;
    if (code == null || code.isEmpty) return;
    final now = DateTime.now();
    // ignore the same code held in front of the camera
    if (code == _last && now.difference(_lastAt).inMilliseconds < 1500) return;
    _last = code;
    _lastAt = now;
    if (widget.continuous) {
      widget.onCode?.call(code);
      setState(() => _count++);
    } else {
      _done = true;
      Navigator.of(context).pop(code);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.continuous ? 'Scanning · $_count added' : 'Scan barcode'),
        actions: [
          IconButton(onPressed: () => _controller.toggleTorch(), icon: const Icon(Icons.flashlight_on_outlined)),
          IconButton(onPressed: () => _controller.switchCamera(), icon: const Icon(Icons.cameraswitch_outlined)),
        ],
      ),
      body: Stack(children: [
        MobileScanner(controller: _controller, onDetect: _onDetect),
        Center(
          child: Container(
            width: 260,
            height: 160,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white, width: 2),
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        if (_last != null)
          Positioned(
            left: 16,
            right: 16,
            bottom: 24,
            child: Card(child: Padding(padding: const EdgeInsets.all(12), child: Text('Last: $_last'))),
          ),
      ]),
      floatingActionButton: widget.continuous
          ? FloatingActionButton.extended(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.check),
              label: const Text('Done'),
            )
          : null,
    );
  }
}
