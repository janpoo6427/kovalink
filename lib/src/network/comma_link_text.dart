// Everything the app says about the connection to the comma, in plain
// Korean. The short line goes on screen; [KovaLinkText.detail] sits under
// "자세히 보기".

/// Why the app is not (or no longer) talking to the comma.
enum KovaLinkProblem {
  /// Nothing like a comma answered on this Wi-Fi or hotspot.
  notFound,

  /// A comma is there (or was) but does not answer in time.
  noAnswer,

  /// The comma refused the token (401).
  tokenRejected,

  /// The certificate pin is not the registered comma's.
  identityMismatch,

  /// The comma refused this phone (403: other network, or phone
  /// connections not allowed on the comma).
  notAllowed,

  /// kovapilot answered with a version the app does not know.
  versionMismatch,

  /// The comma is not registered on this phone yet.
  needsRegistration,

  /// Registered, but the token is gone from the phone's secure storage.
  needsToken,

  /// Something answered at that address, but not a comma.
  notKova,
}

abstract final class KovaLinkText {
  static String message(KovaLinkProblem problem) => switch (problem) {
    KovaLinkProblem.notFound => '같은 와이파이나 핫스팟에서 콤마를 찾지 못했어요.',
    KovaLinkProblem.noAnswer => '이 주소에서 콤마가 응답하지 않아요.',
    KovaLinkProblem.tokenRejected => '연결 토큰이 맞지 않아요. 콤마에 넣은 토큰을 다시 확인해 주세요.',
    KovaLinkProblem.identityMismatch =>
      '등록한 콤마가 아니에요. 인증서가 등록할 때와 달라서 연결 토큰을 보내지 않았어요.',
    KovaLinkProblem.notAllowed => '같은 네트워크에 있지 않거나, 콤마가 휴대폰 연결을 허용하지 않았어요.',
    KovaLinkProblem.versionMismatch =>
      '콤마의 kovapilot 버전이 앱과 맞지 않아요. 앱이나 kovapilot을 업데이트해 주세요.',
    KovaLinkProblem.needsRegistration => '처음 보는 콤마예요. 등록하면 연결할 수 있어요.',
    KovaLinkProblem.needsToken => '이 콤마의 연결 토큰이 휴대폰에 없어요. 다시 등록해 주세요.',
    KovaLinkProblem.notKova => '이 주소에서 콤마를 찾지 못했어요.',
  };

  static String detail(KovaLinkProblem problem) => switch (problem) {
    KovaLinkProblem.notFound =>
      '콤마가 부팅을 마쳤는지 확인해 주세요. '
          '같은 네트워크에서 검색되지 않으면 콤마 화면의 IP로 연결해 보세요.',
    KovaLinkProblem.noAnswer => '콤마의 부팅이 끝났는지와 입력한 IP가 맞는지 확인해 주세요.',
    KovaLinkProblem.tokenRejected =>
      '콤마가 이 토큰을 거절했어요. 관리자가 콤마의 토큰을 바꿨다면 새 토큰으로 다시 등록해 주세요.',
    KovaLinkProblem.identityMismatch =>
      '이 주소의 콤마가 보여 준 인증서 지문이 등록한 지문과 달라요. 다른 콤마이거나 콤마의 인증서가 바뀌었을 수 있어요. '
          '인증서를 바꿨다면 새 지문으로 다시 등록해 주세요.',
    KovaLinkProblem.notAllowed =>
      '콤마가 이 휴대폰의 연결을 받지 않았어요. 휴대폰과 콤마가 같은 와이파이·핫스팟에 있는지, '
          '콤마의 IP로 바로 연결했는지 확인해 주세요.',
    KovaLinkProblem.versionMismatch => '콤마가 알려 준 버전을 이 앱이 읽지 못해요.',
    KovaLinkProblem.needsRegistration =>
      '관리자에게 받은 연결 토큰과 콤마의 인증서 정보(지문 또는 server.pem 파일)가 필요해요.',
    KovaLinkProblem.needsToken => '휴대폰을 바꾸거나 앱 데이터를 지우면 토큰이 지워져요.',
    KovaLinkProblem.notKova => '주소가 맞는지, 콤마가 같은 와이파이·핫스팟에 있는지 확인해 주세요.',
  };
}
