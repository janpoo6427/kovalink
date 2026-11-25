import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:kovalink/src/network/local_endpoint_policy.dart';

enum RoadStreamStatus { idle, connecting, streaming, error }

Map<String, dynamic> buildKovapilotStreamRequest({
  required String sdp,
  required String camera,
}) => {
  'sdp': sdp,
  'cameras': [camera],
  'enabled': true,
  'bridge_services_in': <String>[],
  'bridge_services_out': <String>[],
  'raw': false,
};

class WebRtcRoadStream extends ChangeNotifier {
  final RTCVideoRenderer renderer = RTCVideoRenderer();

  RoadStreamStatus status = RoadStreamStatus.idle;
  String? errorMessage;
  String camera = 'road';

  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _dataChannel;
  bool _rendererInitialized = false;

  bool get hasVideo =>
      status == RoadStreamStatus.streaming && renderer.srcObject != null;

  Future<String?> connect({
    required String signalingEndpoint,
    String camera = 'road',
  }) async {
    final validationError = LocalEndpointPolicy.validateSignaling(
      signalingEndpoint,
    );
    if (validationError != null) {
      _setError(validationError);
      return validationError;
    }
    if (camera != 'road' && camera != 'wideRoad') {
      const message = '지원하지 않는 카메라예요.';
      _setError(message);
      return message;
    }

    await disconnect();
    status = RoadStreamStatus.connecting;
    errorMessage = null;
    this.camera = camera;
    notifyListeners();

    try {
      if (!_rendererInitialized) {
        await renderer.initialize();
        _rendererInitialized = true;
      }

      final peerConnection = await createPeerConnection({
        'iceServers': <Object>[],
        'sdpSemantics': 'unified-plan',
      });
      _peerConnection = peerConnection;

      final gatheringComplete = Completer<void>();
      peerConnection.onIceGatheringState = (state) {
        if (state == RTCIceGatheringState.RTCIceGatheringStateComplete &&
            !gatheringComplete.isCompleted) {
          gatheringComplete.complete();
        }
      };
      peerConnection.onConnectionState = (state) {
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
            state ==
                RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
          _setError('카메라 연결이 끊겼어요.');
        }
      };
      peerConnection.onTrack = (event) {
        if (event.track.kind == 'video' && event.streams.isNotEmpty) {
          renderer.srcObject = event.streams.first;
          status = RoadStreamStatus.streaming;
          notifyListeners();
        }
      };

      _dataChannel = await peerConnection.createDataChannel(
        'data',
        RTCDataChannelInit(),
      );
      await peerConnection.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
      );

      final offer = await peerConnection.createOffer();
      await peerConnection.setLocalDescription(offer);
      if (peerConnection.iceGatheringState !=
          RTCIceGatheringState.RTCIceGatheringStateComplete) {
        await gatheringComplete.future.timeout(const Duration(seconds: 5));
      }
      final localDescription = await peerConnection.getLocalDescription();
      if (localDescription?.sdp == null) {
        throw const FormatException('WebRTC offer를 만들 수 없습니다.');
      }

      final answer = await _postOffer(
        Uri.parse(signalingEndpoint.trim()),
        localDescription!.sdp!,
      );
      await peerConnection.setRemoteDescription(
        RTCSessionDescription(answer.sdp, answer.type),
      );
      return null;
    } on Object {
      const message = '카메라에 연결할 수 없어요. 주소와 네트워크를 확인해 주세요.';
      await _closePeer();
      _setError(message);
      return message;
    }
  }

  Future<_SessionAnswer> _postOffer(Uri endpoint, String sdp) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await client.postUrl(endpoint);
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode(buildKovapilotStreamRequest(sdp: sdp, camera: camera)),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 12),
      );
      final body = await utf8.decodeStream(response);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          'signaling HTTP ${response.statusCode}: $body',
          uri: endpoint,
        );
      }
      final json = jsonDecode(body);
      if (json is! Map<String, dynamic> ||
          json['sdp'] is! String ||
          json['type'] is! String) {
        throw const FormatException('잘못된 WebRTC answer입니다.');
      }
      return _SessionAnswer(
        sdp: json['sdp'] as String,
        type: json['type'] as String,
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<void> disconnect() async {
    await _closePeer();
    status = RoadStreamStatus.idle;
    errorMessage = null;
    notifyListeners();
  }

  Future<void> _closePeer() async {
    if (_rendererInitialized) {
      renderer.srcObject = null;
    }
    await _dataChannel?.close();
    _dataChannel = null;
    await _peerConnection?.close();
    await _peerConnection?.dispose();
    _peerConnection = null;
  }

  void _setError(String message) {
    status = RoadStreamStatus.error;
    errorMessage = message;
    notifyListeners();
  }

  @override
  void dispose() {
    _closePeer();
    if (_rendererInitialized) renderer.dispose();
    super.dispose();
  }
}

class _SessionAnswer {
  const _SessionAnswer({required this.sdp, required this.type});
  final String sdp;
  final String type;
}
