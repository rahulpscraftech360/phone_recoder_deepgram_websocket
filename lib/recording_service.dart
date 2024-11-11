// recording_service.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:web_socket_channel/io.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';

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

class RecordingService {
  bool isRecording = false;
  bool isWebSocketConnected = false;
  IOWebSocketChannel? channel;
  String transcription = '';
  Timer? streamingTimer;
  Timer? keepAliveTimer;
  final AudioRecorder _audioRecorder = AudioRecorder();

  Future<void> initializeWebSocket({
    required VoidCallback onWebsocketConnectionSuccess,
    required void Function(dynamic) onWebsocketConnectionFailed,
    required void Function(int?, String?) onWebsocketConnectionClosed,
    required void Function(dynamic) onWebsocketConnectionError,
    required void Function(List<TranscriptSegment>) onMessageReceived,
    required int sampleRate,
    required String deepgramApiKey,
  }) async {
    try {
      final uri = Uri.parse(
        'wss://api.deepgram.com/v1/listen?encoding=linear16&sample_rate=$sampleRate&channels=1',
      );

      channel = IOWebSocketChannel.connect(
        uri,
        headers: {
          'Authorization': 'Token $deepgramApiKey',
          'Content-Type': 'audio/raw',
        },
      );

      await channel?.ready;
      onWebsocketConnectionSuccess();
    } catch (e) {
      onWebsocketConnectionFailed(e);
    }
  }

  Future<void> startRecording(
      VoidCallback onWebsocketConnectionSuccess,
      void Function(dynamic) onWebsocketConnectionFailed,
      void Function(int?, String?) onWebsocketConnectionClosed,
      void Function(dynamic) onWebsocketConnectionError,
      void Function(List<TranscriptSegment>) onMessageReceived) async {
    final sampleRate = 16000;
    final deepgramApiKey = 'your_deepgram_api_key_here';

    await initializeWebSocket(
      onWebsocketConnectionSuccess: onWebsocketConnectionSuccess,
      onWebsocketConnectionFailed: onWebsocketConnectionFailed,
      onWebsocketConnectionClosed: onWebsocketConnectionClosed,
      onWebsocketConnectionError: onWebsocketConnectionError,
      onMessageReceived: onMessageReceived,
      sampleRate: sampleRate,
      deepgramApiKey: deepgramApiKey,
    );

    final path = await _getRecordingPath();
    await _audioRecorder.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
      ),
      path: path,
    );

    isRecording = true;
  }

  Future<void> stopRecording() async {
    await _audioRecorder.stop();
    channel?.sink.close();
    isRecording = false;
  }

  Future<String> _getRecordingPath() async {
    final directory = await getTemporaryDirectory();
    return '${directory.path}/temp_recording.wav';
  }
}
