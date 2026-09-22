import XCTest
@testable import TaskTickApp

/// 企业微信自建应用 channel (issue #54). The parts that can be checked without a
/// corpid: validation order, URL and payload shape, content clamping, and how
/// the API's always-HTTP-200 answers are read back.
final class WeComPushTests: XCTestCase {

    private func makeChannel(
        corpID: String = "wwabc123",
        secret: String = "s3cr3t",
        agentID: String = "1000002",
        toUser: String = "@all"
    ) -> PushChannel {
        PushChannel(
            kind: .wecomApp,
            name: "WeCom",
            token: secret,
            corpID: corpID,
            agentID: agentID,
            toUser: toUser
        )
    }

    // MARK: - Validation

    func testFullyConfiguredChannelIsValid() {
        XCTAssertNil(makeChannel().validationError)
        XCTAssertTrue(makeChannel().isReadyToSend)
    }

    /// The fixed endpoint means an empty serverURL must NOT read as `.emptyURL`
    /// — that guard used to run for every kind.
    func testEmptyServerURLIsNotAnError() {
        var channel = makeChannel()
        channel.serverURL = ""
        XCTAssertNil(channel.validationError)
    }

    func testMissingFieldsReportedInEditorOrder() {
        XCTAssertEqual(makeChannel(corpID: "  ").validationError, .missingCorpID)
        XCTAssertEqual(makeChannel(secret: "").validationError, .missingSecret)
        XCTAssertEqual(makeChannel(agentID: "").validationError, .invalidAgentID)
        XCTAssertEqual(makeChannel(toUser: " ").validationError, .missingRecipient)
    }

    func testNonNumericAgentIDRejected() {
        XCTAssertEqual(makeChannel(agentID: "app-1").validationError, .invalidAgentID)
        XCTAssertNil(makeChannel(agentID: "  1000002  ").validationError)
    }

    /// Clearing the recipient box must not silently mean "@all" — that would
    /// widen the audience to the whole company by deleting text.
    func testClearedRecipientIsAnErrorNotImplicitAll() {
        XCTAssertEqual(makeChannel(toUser: "").validationError, .missingRecipient)
        XCTAssertEqual(PushChannel(kind: .wecomApp).toUser, "@all")
    }

    func testOtherKindsStillRequireAURL() {
        XCTAssertEqual(PushChannel(kind: .bark, serverURL: "").validationError, .emptyURL)
        XCTAssertEqual(PushChannel(kind: .gotify, serverURL: "").validationError, .emptyURL)
        XCTAssertEqual(PushChannel(kind: .webhook, serverURL: "").validationError, .emptyURL)
    }

    // MARK: - Endpoints

    func testTokenURLCarriesBothCredentials() throws {
        let url = try XCTUnwrap(WeComEndpoint.tokenURL(corpID: "wwabc", secret: "sec ret/+"))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "qyapi.weixin.qq.com")
        XCTAssertEqual(components.path, "/cgi-bin/gettoken")
        XCTAssertEqual(components.queryItems?.first { $0.name == "corpid" }?.value, "wwabc")
        // URLComponents percent-encodes on the way out; the decoded value has
        // to survive a secret containing URL-significant characters.
        XCTAssertEqual(components.queryItems?.first { $0.name == "corpsecret" }?.value, "sec ret/+")
    }

    func testSendURLCarriesAccessToken() throws {
        let url = try XCTUnwrap(WeComEndpoint.sendURL(accessToken: "tok123"))
        XCTAssertEqual(url.path, "/cgi-bin/message/send")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems?.first { $0.name == "access_token" }?.value, "tok123")
    }

    // MARK: - Message payload

    func testPayloadShape() throws {
        let payload = try XCTUnwrap(
            WeComEndpoint.messagePayload(channel: makeChannel(toUser: "alice|bob"),
                                        title: "TaskTick", body: "done")
        )
        XCTAssertEqual(payload["touser"] as? String, "alice|bob")
        XCTAssertEqual(payload["msgtype"] as? String, "text")
        // agentid must be a number, not a string — 企业微信 rejects the string.
        XCTAssertEqual(payload["agentid"] as? Int, 1000002)
        XCTAssertEqual((payload["text"] as? [String: String])?["content"], "TaskTick\ndone")
    }

    func testPayloadIsSerializableJSON() throws {
        let payload = try XCTUnwrap(
            WeComEndpoint.messagePayload(channel: makeChannel(), title: "T", body: "B")
        )
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: payload))
    }

    func testPayloadSkipsEmptyTitleOrBody() throws {
        let titleOnly = try XCTUnwrap(
            WeComEndpoint.messagePayload(channel: makeChannel(), title: "T", body: "   ")
        )
        XCTAssertEqual((titleOnly["text"] as? [String: String])?["content"], "T")

        let bodyOnly = try XCTUnwrap(
            WeComEndpoint.messagePayload(channel: makeChannel(), title: "", body: "B")
        )
        XCTAssertEqual((bodyOnly["text"] as? [String: String])?["content"], "B")
    }

    func testPayloadNilWhenAgentIDNotNumeric() {
        XCTAssertNil(
            WeComEndpoint.messagePayload(channel: makeChannel(agentID: "nope"), title: "T", body: "B")
        )
    }

    // MARK: - Content clamping

    func testShortContentUntouched() {
        XCTAssertEqual(WeComEndpoint.clampedContent("hello"), "hello")
    }

    func testLongContentClampedToByteLimit() {
        let clamped = WeComEndpoint.clampedContent(String(repeating: "a", count: 5000))
        XCTAssertTrue(clamped.hasSuffix("…"))
        XCTAssertEqual(clamped.count, WeComEndpoint.maxContentBytes + 1)
    }

    /// A cut that lands mid-character must back off rather than produce a
    /// string Foundation can't encode.
    func testClampNeverSplitsAMultibyteCharacter() {
        let clamped = WeComEndpoint.clampedContent(String(repeating: "中", count: 2000), maxBytes: 10)
        XCTAssertEqual(clamped, "中中中…")
        XCTAssertLessThanOrEqual(Data(clamped.dropLast().utf8).count, 10)
    }

    // MARK: - Credential redaction

    /// Both endpoints put a credential in the query string, so nothing that
    /// quotes a failing URL may reach NSLog verbatim.
    func testRedactionMasksCredentialsInErrorText() {
        let message = WeComEndpoint.redacted(
            "The request to https://qyapi.weixin.qq.com/cgi-bin/gettoken?corpid=wwabc&corpsecret=LongSecretValue timed out.",
            hiding: ["LongSecretValue"]
        )
        XCTAssertFalse(message.contains("LongSecretValue"))
        XCTAssertTrue(message.contains("***"))
    }

    /// A short value would match ordinary words in the sentence; real secrets
    /// and tokens are long.
    func testRedactionIgnoresShortValues() {
        let message = WeComEndpoint.redacted("timed out", hiding: ["out", ""])
        XCTAssertEqual(message, "timed out")
    }

    // MARK: - API responses

    private func decode(_ json: String) throws -> WeComAPIResponse {
        try JSONDecoder().decode(WeComAPIResponse.self, from: Data(json.utf8))
    }

    func testSuccessHasNoError() throws {
        XCTAssertNil(try decode(#"{"errcode":0,"errmsg":"ok"}"#).pushError)
    }

    func testErrcodeBecomesServerMessageWithCode() throws {
        let error = try decode(#"{"errcode":60020,"errmsg":"not allow to access from your ip"}"#).pushError
        guard case .serverMessage(let message) = error else {
            return XCTFail("expected a server message, got \(String(describing: error))")
        }
        XCTAssertTrue(message.contains("not allow to access from your ip"))
        XCTAssertTrue(message.contains("60020"))
    }

    /// The classic 自建应用 mistake: a UserID that's really a name or a phone
    /// number. 企业微信 answers errcode 0, and the push reaches nobody.
    func testInvalidUserWithErrcodeZeroStillReportsFailure() throws {
        let error = try decode(#"{"errcode":0,"errmsg":"ok","invaliduser":"zhangsan"}"#).pushError
        guard case .serverMessage(let message) = error else {
            return XCTFail("expected a server message, got \(String(describing: error))")
        }
        XCTAssertTrue(message.contains("zhangsan"))
    }

    func testEmptyInvalidUserIsNotAFailure() throws {
        XCTAssertNil(try decode(#"{"errcode":0,"errmsg":"ok","invaliduser":""}"#).pushError)
    }

    func testExpiredTokenCodesTriggerRetry() throws {
        for code in [40014, 42001, 41001] {
            XCTAssertTrue(try decode(#"{"errcode":\#(code),"errmsg":"x"}"#).isExpiredToken,
                          "errcode \(code) should be retryable")
        }
        XCTAssertFalse(try decode(#"{"errcode":60020,"errmsg":"x"}"#).isExpiredToken)
        XCTAssertFalse(try decode(#"{"errcode":0,"errmsg":"ok"}"#).isExpiredToken)
    }

    func testInterpretRoutesThroughTheAPIShape() {
        let ok = PushRequestBuilder.interpret(
            kind: .wecomApp, status: 200, data: Data(#"{"errcode":0,"errmsg":"ok"}"#.utf8)
        )
        XCTAssertNil(ok)

        let failed = PushRequestBuilder.interpret(
            kind: .wecomApp, status: 200, data: Data(#"{"errcode":81013,"errmsg":"no permission"}"#.utf8)
        )
        XCTAssertNotNil(failed)
    }

    // MARK: - Misconfigured channels never hit the network

    func testIncompleteChannelFailsBeforeSending() async {
        let result = await PushDispatcher.post(
            channel: makeChannel(corpID: ""), title: "t", body: "b"
        )
        guard case .failure(let error) = result else {
            return XCTFail("expected failure for a channel with no corp ID")
        }
        XCTAssertEqual(error, .missingCorpID)
    }

    // MARK: - Persistence

    func testChannelRoundTripsThroughJSON() throws {
        let channel = makeChannel(toUser: "alice")
        let data = try JSONEncoder().encode([channel])
        XCTAssertEqual(try JSONDecoder().decode([PushChannel].self, from: data), [channel])
    }

    /// Configs written before #54 have none of these fields; the recipient has
    /// to come back as the documented default rather than empty.
    func testDecodingOlderConfigFillsWeComDefaults() throws {
        let json = Data(#"[{"kind":"bark","serverURL":"https://api.day.app/key"}]"#.utf8)
        let channels = try JSONDecoder().decode([PushChannel].self, from: json)
        XCTAssertEqual(channels[0].corpID, "")
        XCTAssertEqual(channels[0].agentID, "")
        XCTAssertEqual(channels[0].toUser, "@all")
    }

    func testRawValueIsStableAcrossBuilds() throws {
        XCTAssertEqual(PushProviderKind.wecomApp.rawValue, "wecom_app")
        let json = Data(#"[{"kind":"wecom_app"}]"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode([PushChannel].self, from: json)[0].kind, .wecomApp)
    }
}
