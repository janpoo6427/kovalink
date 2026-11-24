import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/services/web_rtc_road_stream.dart';

void main() {
  test('matches kovapilot StreamRequestBody fields', () {
    final request = buildKovapilotStreamRequest(
      sdp: 'offer-sdp',
      camera: 'road',
    );

    expect(request.keys, {
      'sdp',
      'cameras',
      'enabled',
      'bridge_services_in',
      'bridge_services_out',
      'raw',
    });
    expect(request['cameras'], ['road']);
    expect(request, isNot(contains('type')));
  });
}
