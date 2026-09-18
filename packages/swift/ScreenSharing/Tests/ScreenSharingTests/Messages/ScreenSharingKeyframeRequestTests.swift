import Testing
@testable import ScreenSharing

struct ScreenSharingKeyframeRequestTests {
  @Test func ordinaryFramesDoNotForceKeyframes() {
    var request = ScreenSharingKeyframeRequest()
    #expect(!request.isPending)
    let noUnrequestedAttempt = request.beginAttempt() == nil
    #expect(noUnrequestedAttempt)
    let noUnsolicitedRetry = !request.complete(nil, producedKeyFrame: true)
    #expect(noUnsolicitedRetry)
  }

  @Test func requestSurvivesUntilAdmissionAndUsableOutput() throws {
    var request = ScreenSharingKeyframeRequest()
    request.request()
    // An admission drop does not begin an attempt or acknowledge the request.
    #expect(request.isPending)
    let attemptCandidate = request.beginAttempt()
    let attempt = try #require(attemptCandidate)
    #expect(request.isPending)
    let noParallelAttempt = request.beginAttempt() == nil
    #expect(noParallelAttempt)
    let noRetryAfterSuccess = !request.complete(attempt, producedKeyFrame: true)
    #expect(noRetryAfterSuccess)
    #expect(!request.isPending)
    let noAttemptAfterSuccess = request.beginAttempt() == nil
    #expect(noAttemptAfterSuccess)
  }

  @Test func droppedOrUnusableOutputRetriesWithoutAnotherTransportRequest() throws {
    var request = ScreenSharingKeyframeRequest()
    request.request()
    let firstCandidate = request.beginAttempt()
    let first = try #require(firstCandidate)
    let retryRequired = request.complete(first, producedKeyFrame: false)
    #expect(retryRequired)
    #expect(request.isPending)
    let retryCandidate = request.beginAttempt()
    let retry = try #require(retryCandidate)
    #expect(retry != first)
    let retrySucceeded = !request.complete(retry, producedKeyFrame: true)
    #expect(retrySucceeded)
    #expect(!request.isPending)
  }

  @Test func earlierKeyframeCannotConsumeARequestMadeDuringEncoding() throws {
    var request = ScreenSharingKeyframeRequest()
    request.request()
    let firstCandidate = request.beginAttempt()
    let first = try #require(firstCandidate)
    request.request()
    let newRequestWaitsForOutput = request.beginAttempt() == nil
    #expect(newRequestWaitsForOutput)
    request.complete(first, producedKeyFrame: true)
    #expect(request.isPending)
    let nextCandidate = request.beginAttempt()
    let next = try #require(nextCandidate)
    request.complete(next, producedKeyFrame: true)
    #expect(!request.isPending)
  }

  @Test func requestsBeforeAdmissionCoalesceIntoOneAttempt() throws {
    var request = ScreenSharingKeyframeRequest()
    request.request()
    request.request()
    let attemptCandidate = request.beginAttempt()
    let attempt = try #require(attemptCandidate)
    request.complete(attempt, producedKeyFrame: true)
    #expect(!request.isPending)
    let noRedundantAttempt = request.beginAttempt() == nil
    #expect(noRedundantAttempt)
  }

  @Test func lateCompletionCannotAcknowledgeOrReleaseARetry() throws {
    var request = ScreenSharingKeyframeRequest()
    request.request()
    let firstCandidate = request.beginAttempt()
    let first = try #require(firstCandidate)
    request.complete(first, producedKeyFrame: false)
    let retryCandidate = request.beginAttempt()
    let retry = try #require(retryCandidate)
    let lateSuccessIgnored = !request.complete(first, producedKeyFrame: true)
    #expect(lateSuccessIgnored)
    let lateFailureIgnored = !request.complete(first, producedKeyFrame: false)
    #expect(lateFailureIgnored)
    #expect(request.isPending)
    let retryStillInFlight = request.beginAttempt() == nil
    #expect(retryStillInFlight)
    request.complete(retry, producedKeyFrame: true)
    #expect(!request.isPending)
  }
}
