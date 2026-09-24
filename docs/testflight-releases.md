# iOS TestFlight releases

**Build** archives and signs an App Store eligible iOS build on every push to main.
**Publish Alpha** runs every 30 minutes (or when dispatched manually), ships the newest
successful build, and uploads its iOS build to the internal Alpha group. Builds
superseded between runs are never uploaded, so daily uploads stay under Apple's
per-app limit however often main moves. If Apple reports that limit anyway, the
upload is skipped with a warning and retried on the next run.

Public TestFlight publication uses the separate, manually triggered **Publish Beta**
workflow. **Publish Stable** releases macOS/server artifacts and does not submit an iOS
build for external testing.

## Submit an iOS beta

In GitHub Actions, open **Publish Beta**, choose **Run workflow** on **main**, and enter
the published Alpha tag whose iOS build you want to promote:

```sh
gh workflow run publish-beta.yml --ref main -f alpha_tag=vVERSION-alpha.BUILD
```

The Alpha can be older than current main, but its Build run must still retain
its iOS artifact (14 days). A Stable release is not required. The workflow promotes
the build Publish Alpha already uploaded, without rebuilding or uploading again.

The release job verifies the Alpha artifact checksum, app, version, build number,
source commit, and Alpha tag before changing TestFlight. It adds the Alpha
changelog to **What to Test**, assigns the external group, enables automatic
notifications after approval, and submits the build for beta review if needed.
The workflow ends after submission; Apple review can finish later. Its summary
distinguishes submission from availability to testers.

## One-time App Store Connect setup

Under **TestFlight > Test Information**, save the beta description, feedback email,
review contact details, demo sign-in credentials, and review notes. These remain
in App Store Connect; no reviewer password is stored in GitHub or the repository.
The release job reports missing fields before making changes.

The default external group is **Beta**. If only the former **Public Beta** group
exists, the job renames it in place, preserving its builds, testers, and public
link. Otherwise, it creates **Beta** if missing.
To use an existing group, set the GitHub repository variable
`IOS_TESTFLIGHT_EXTERNAL_GROUP` to its exact name. Internal groups are rejected.
Enable the group's public invitation link in App Store Connect when ready to
share it. The workflow preserves existing invitations, links, limits, and testers.

The job uses the same four Apple signing/API secrets as the Build workflow. No new secrets
are needed. The API key must have Account Holder, Admin, or App Manager access.
See Apple's [external testing setup](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers).

## Recovery and verification

Publish Alpha's TestFlight job never holds back the macOS release. After a
successful upload it attaches `ios-testflight-build.json` to the Alpha prerelease;
until that marker exists, every Publish Alpha run retries the upload, resuming an
already-uploaded build instead of sending it again. To run it now instead of
waiting for the schedule:

```sh
gh workflow run publish-alpha.yml --ref main
```

Rerun a failed Publish Beta run with the same Alpha tag to resume. Existing group
membership, notes, and pending or approved submissions are reused. Rejected,
expired, internal-only, or non-reviewable builds fail with an explanation.
Resolve missing information, export compliance, or Apple's rejection in App Store
Connect before retrying. Apple's submission limits still apply.

Select **check_only** when running the workflow to validate the selected build
and App Store Connect setup without changing anything in TestFlight:

```sh
gh workflow run publish-beta.yml --ref main -f alpha_tag=vVERSION-alpha.BUILD -F check_only=true
```

For the same read-only check locally with Apple credentials, repository tags,
and the Alpha artifact downloaded:

```sh
node scripts/release/promote-ios-testflight.mjs VERSION ARTIFACT_DIRECTORY RELEASE_NOTES --check
```

Supply the same Apple environment variables as the Build workflow, plus
`CODEVISOR_BUILD_NUMBER` and `CODEVISOR_SOURCE_REVISION` from the Alpha provenance.
The check verifies artifact identity and live TestFlight readiness without
creating groups, editing notes, notifying testers, or submitting a review.

App Store version submission is not part of this workflow yet.
