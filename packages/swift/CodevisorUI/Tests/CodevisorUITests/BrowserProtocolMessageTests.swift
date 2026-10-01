import CodevisorClient
import Foundation
import Testing
@testable import CodevisorUI

@Suite("Browser protocol messages")
struct BrowserProtocolMessageTests {
  private func json(_ data: Data) throws -> NSDictionary {
    try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
  }

  @Test func sessionRepliesForwardOnlyTheirResultUnderTheClientId() throws {
    // Chromium appends the child session after the result. CEF's own
    // OnDevToolsMethodResult splitter would include it in the "result".
    let reply = Data(#"{"id":1000000007,"result":{"data":"iVBORw0K\"}\\"},"sessionId":"7F1C"}"#.utf8)
    let result = try BrowserProtocolMessage.result(ofReply: reply)
    let response = BrowserProtocolMessage.response(id: Data(#""client-3""#.utf8), result: result)
    #expect(try json(response) == ["id": "client-3", "result": ["data": #"iVBORw0K"}\"#]])
  }

  @Test func errorRepliesSurfaceTheBrowserMessage() {
    let reply = Data(#"{"id":4,"error":{"code":-32000,"message":"No node with given id"},"sessionId":"A"}"#.utf8)
    #expect(throws: BrowserProtocolError("No node with given id")) {
      try BrowserProtocolMessage.result(ofReply: reply)
    }
  }

  @Test func eventSessionsAreReadAndRewrittenAtTheTopLevelOnly() throws {
    let event = Data(
      #"{"method":"Target.attachedToTarget","params":{"sessionId":"CHILD","targetInfo":{"title":"a,\"}b"}},"sessionId":"NATIVE"}"#
        .utf8)
    let message = try #require(BrowserProtocolMessage(event))
    #expect(message.string("method") == "Target.attachedToTarget")
    #expect(message.string("sessionId") == "NATIVE")
    #expect(message.object("params")?["sessionId"] as? String == "CHILD")
    let rewritten = message.setting("sessionId", to: BrowserProtocolMessage.encode("virtual"))
    #expect(
      String(decoding: rewritten, as: UTF8.self)
        == #"{"method":"Target.attachedToTarget","params":{"sessionId":"CHILD","targetInfo":{"title":"a,\"}b"}},"sessionId":"virtual"}"#
    )
  }

  @Test func clientRequestsAreAddressedRegardlessOfMemberOrder() throws {
    let request = Data(
      #" { "sessionId" : "S", "params" : {"expression":"1 + [2][0]"}, "id" : 12, "method":"Runtime.evaluate" } "#.utf8)
    let message = try #require(BrowserProtocolMessage(request))
    #expect(message.integer("id") == 12)
    #expect(message.string("sessionId") == "S")
    #expect(message.string("method") == "Runtime.evaluate")
    #expect(message.raw("params") == Data(#"{"expression":"1 + [2][0]"}"#.utf8))
    #expect(
      try json(message.setting("id", to: nil)) == [
        "sessionId": "S", "params": ["expression": "1 + [2][0]"], "method": "Runtime.evaluate",
      ])
  }

  @Test(arguments: [#"{"id":1,"result":{}"#, #"{"id":1 "result":{}}"#, #"["id",1]"#, #"{"id":"1}"#, ""])
  func truncatedOrNonObjectMessagesAreRejected(_ text: String) {
    #expect(BrowserProtocolMessage(Data(text.utf8)) == nil)
  }

  @Test func linesSplitAcrossChunksAreReassembledInOrder() {
    var buffer = BrowserProtocolLineBuffer()
    #expect(buffer.append(Data(#"{"id":1}"#.utf8)).isEmpty)
    #expect(buffer.append(Data("\n{\"id\"".utf8)) == [Data(#"{"id":1}"#.utf8)])
    #expect(buffer.pendingCount == 5)
    #expect(buffer.append(Data(":2}\n{\"id\":3}\n{".utf8)) == [Data(#"{"id":2}"#.utf8), Data(#"{"id":3}"#.utf8)])
    #expect(buffer.pendingCount == 1)
  }

  @Test func chromiumCookiesKeepOnlyShareableCookies() throws {
    var cookies = BrowserProtocolCookies()
    let reply = Data(
      #"""
      {"id":9,"result":{"cookies":[
        {"name":"sid","value":"1","domain":".example.test","path":"/","expires":-1,"secure":true,"httpOnly":true,"sameSite":"Lax"},
        {"name":"pref","value":"2","domain":"example.test","path":"/a","expires":1900000000.5,"secure":false,"httpOnly":false},
        {"name":"chip","value":"3","domain":"example.test","path":"/","partitionKey":{"topLevelSite":"https://a.test"}},
        {"name":"opaque","value":"4","domain":"example.test","path":"/","partitionKeyOpaque":true}
      ]}}
      """#.utf8)
    #expect(
      try cookies.cookies(fromReply: reply) == [
        BrowserCookie(
          name: "sid", value: "1", domain: ".example.test", path: "/", secure: true, httpOnly: true, sameSite: "lax"),
        BrowserCookie(
          name: "pref", value: "2", domain: "example.test", path: "/a", secure: false, httpOnly: false,
          sameSite: "unspecified", expires: 1_900_000_000.5),
      ])
    #expect(throws: BrowserProtocolError("Browser closed")) {
      try cookies.cookies(fromReply: Data(#"{"error":{"message":"Browser closed"}}"#.utf8))
    }
  }
}
