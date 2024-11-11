import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:web_socket_channel/io.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  runApp(const MaterialApp(home: RecordingScreen()));
}

class TranscriptSegment {
  final String text;
  final String speaker;
  final bool isUser;
  final double start;
  final double end;

  TranscriptSegment({
    required this.text,
    required this.speaker,
    required this.isUser,
    required this.start,
    required this.end,
  });
}

Future<IOWebSocketChannel?> streamingTranscript({
  required VoidCallback onWebsocketConnectionSuccess,
  required void Function(dynamic) onWebsocketConnectionFailed,
  required void Function(int?, String?) onWebsocketConnectionClosed,
  required void Function(dynamic) onWebsocketConnectionError,
  required void Function(List<TranscriptSegment>) onMessageReceived,
  required int sampleRate,
  required String deepgramApiKey,
}) async {
  try {
    // Initialize WebSocket connection to Deepgram with fixed parameters
    final Uri uri = Uri.parse(
      'wss://api.deepgram.com/v1/listen?encoding=linear16&sample_rate=$sampleRate&channels=1',
    );

    final channel = IOWebSocketChannel.connect(
      uri,
      headers: {
        'Authorization': 'Token e19942922008143bf76a75cb75b92853faa0b0da',
        'Content-Type': 'audio/raw',
      },
    );

    await channel.ready;
    debugPrint('WebSocket connection opened');
    onWebsocketConnectionSuccess();

    // Start KeepAlive mechanism
    Timer? keepAliveTimer;
    const keepAliveInterval = Duration(seconds: 7);
    const silenceTimeout = Duration(seconds: 30);
    DateTime? lastAudioTime;

    void startKeepAlive() {
      keepAliveTimer = Timer.periodic(keepAliveInterval, (timer) {
        try {
          final keepAliveMsg = jsonEncode({'type': 'KeepAlive'});
          channel.sink.add(keepAliveMsg);
          // log('Sent KeepAlive message');
        } catch (e) {
          debugPrint('Error sending KeepAlive message: $e');
        }
      });
    }

    void stopKeepAlive() {
      keepAliveTimer?.cancel();
    }

    void checkSilence() {
      if (lastAudioTime != null &&
          DateTime.now().difference(lastAudioTime!) > silenceTimeout) {
        debugPrint(
            'Silence detected for more than 30 seconds. Stopping KeepAlive.');
        stopKeepAlive();
      }
    }

    startKeepAlive();

    // Listen for incoming messages from the WebSocket
    channel.stream.listen(
      (event) {
        try {
          final data = jsonDecode(event);
          if (data['type'] == 'Results') {
            print(data);
            final alternatives = data['channel']['alternatives'];
            if (alternatives is List && alternatives.isNotEmpty) {
              final transcript = alternatives[0]['transcript'];
              if (transcript is String && transcript.isNotEmpty) {
                final segment = TranscriptSegment(
                  text: transcript,
                  speaker: '1',
                  isUser: false,
                  start: (data['start'] as double?) ?? 0.0,
                  end: ((data['start'] as double?) ?? 0.0) +
                      ((data['duration'] as double?) ?? 0.0),
                );
                onMessageReceived([segment]);
                lastAudioTime = DateTime.now();
              }
            }
          } else {
            debugPrint('Unknown event type: ${data['type']}');
          }
        } catch (e) {
          debugPrint('Error processing event: $e');
          debugPrint('Raw event: $event');
        }
      },
      onError: (error) {
        debugPrint('WebSocket error: $error');
        onWebsocketConnectionError(error);
      },
      onDone: () {
        debugPrint('WebSocket connection closed');
        onWebsocketConnectionClosed(channel.closeCode, channel.closeReason);
        stopKeepAlive();
      },
    );

    return channel;
  } catch (e, stackTrace) {
    debugPrint('Error initializing WebSocket: $e');
    onWebsocketConnectionFailed(e);
    return null;
  }
}

class RecordingScreen extends StatefulWidget {
  const RecordingScreen({super.key});

  @override
  State<RecordingScreen> createState() => _RecordingScreenState();
}

class _RecordingScreenState extends State<RecordingScreen> {
  bool isRecording = false;
  bool _isWebSocketConnected = false;
  late final AudioRecorder _audioRecorder;
  IOWebSocketChannel? _channel;
  String _transcription = '';
  String? _currentRecordingPath;
  Timer? _streamingTimer;
  Timer? _keepAliveTimer;

  @override
  void initState() {
    _audioRecorder = AudioRecorder();
    super.initState();
  }

  @override
  void dispose() {
    _audioRecorder.dispose();
    _stopWebSocket();
    _streamingTimer?.cancel();
    super.dispose();
  }

  Future<void> _initializeWebSocket() async {
    final deepgramApiKey = 'e19942922008143bf76a75cb75b92853faa0b0da';
    final sampleRate = 16000;

    _channel = await streamingTranscript(
      onWebsocketConnectionSuccess: () {
        setState(() {
          _isWebSocketConnected = true;
        });
        _startKeepAlive();
      },
      onWebsocketConnectionFailed: (error) {
        debugPrint('WebSocket connection failed: $error');
      },
      onWebsocketConnectionClosed: (code, reason) {
        debugPrint('WebSocket closed (code: $code, reason: $reason)');
        setState(() {
          _isWebSocketConnected = false;
        });
        _stopWebSocket();
      },
      onWebsocketConnectionError: (error) {
        debugPrint('WebSocket error: $error');
        setState(() {
          _isWebSocketConnected = false;
        });
      },
      onMessageReceived: (segments) {
        setState(() {
          _transcription +=
              segments.map((segment) => segment.text).join(' ') + ' ';
        });
      },
      sampleRate: sampleRate,
      deepgramApiKey: deepgramApiKey,
    );
  }

  void _stopWebSocket() {
    _keepAliveTimer?.cancel();
    _channel?.sink.close();
    _channel = null;
    setState(() {
      _isWebSocketConnected = false;
    });
  }

  void _startKeepAlive() {
    _keepAliveTimer?.cancel();

    _keepAliveTimer = Timer.periodic(const Duration(seconds: 7), (timer) {
      if (_isWebSocketConnected && _channel != null) {
        final keepAliveMsg = jsonEncode({'type': 'KeepAlive'});
        debugPrint('Sending keep-alive message...');
        _channel!.sink.add(keepAliveMsg);
      } else {
        timer.cancel();
      }
    });
  }

  Future<String> _getRecordingPath() async {
    final directory = await getTemporaryDirectory();
    return '${directory.path}/temp_recording.wav';
  }

  Future<void> _startRecording() async {
    try {
      debugPrint('Starting recording and Deepgram connection...');

      final recordingPath = await _getRecordingPath();
      _currentRecordingPath = recordingPath;

      await _initializeWebSocket();

      await _audioRecorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: recordingPath,
      );

      _streamingTimer =
          Timer.periodic(const Duration(milliseconds: 1000), (_) async {
        final path = _currentRecordingPath;
        if (path != null &&
            await File(path).exists() &&
            _isWebSocketConnected) {
          try {
            final file = File(path);
            print("send data");
            // final bytes = await file.readAsBytes();

            final bytes = await file.readAsBytes();
            if (bytes.isNotEmpty && _channel != null) {
              _channel!.sink.add(bytes);
              await file.writeAsBytes([]); // Clear file after sending
            }
          } catch (e) {
            debugPrint('Error reading audio file: $e');
          }
        }
      });
    } catch (e) {
      debugPrint('Error starting recording: $e');
      _stopWebSocket();
    }
  }

  Future<void> _stopRecording() async {
    try {
      _streamingTimer?.cancel();
      await _audioRecorder.stop();
      _stopWebSocket();

      final path = _currentRecordingPath;
      if (path != null) {
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
        }
      }
    } catch (e) {
      debugPrint('Error stopping recording: $e');
    }
  }

  void _toggleRecording() async {
    if (!isRecording) {
      final status = await Permission.microphone.request();
      if (status == PermissionStatus.granted) {
        setState(() {
          isRecording = true;
          _transcription = ''; // Clear previous transcription
        });
        await _startRecording();
      }
    } else {
      setState(() {
        isRecording = false;
      });
      await _stopRecording();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Expanded(
            child: Container(
              margin: const EdgeInsets.all(16),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.blue),
                borderRadius: BorderRadius.circular(12),
              ),
              child: SingleChildScrollView(
                child: Text(
                  _transcription.isEmpty ? 'Start speaking...' : _transcription,
                  style: const TextStyle(fontSize: 18),
                ),
              ),
            ),
          ),
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            height: 100,
            width: 100,
            margin: const EdgeInsets.only(bottom: 32),
            padding: EdgeInsets.all(isRecording ? 25 : 15),
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              border: Border.all(
                color: Colors.blue,
                width: isRecording ? 8 : 3,
              ),
            ),
            child: GestureDetector(
              onTap: _toggleRecording,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                decoration: BoxDecoration(
                  color: Colors.blue,
                  shape: isRecording ? BoxShape.rectangle : BoxShape.circle,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
