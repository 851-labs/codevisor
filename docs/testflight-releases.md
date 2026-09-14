# iOS TestFlight releases

**Build Alpha** uploads an App Store eligible iOS build and assigns it only to the internal
Alpha group. Public TestFlight publication uses the separate, manually triggered
**Publish Beta** workflow. **Publish Stable** releases macOS/server artifacts and does not submit
an iOS build for external testing.

## Submit an iOS beta

In GitHub Actions, open **Publish Beta**, choose **Run workflow** on
**main**, and enter the successful **Build Alpha run ID** containing the iOS build you
want to promote. The run ID is the number at the end of its Actions URL.

```sh
gh workflow run publish-ios-testflight.yml --ref main -f alpha_run_id=RUN_ID
```

The selected Alpha can be older than current main. It must have completed
successfully on main, have its published Alpha tag, and still retain its build
artifacts (currently 14 days). A Stable release is not required. The workflow
promotes the existing uploaded build without rebuilding or uploading another IPA.

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

The job uses the same four Apple signing/API secrets as Build Alpha. No new secrets
are needed. The API key must have Account Holder, Admin, or App Manager access.
See Apple's [external testing setup](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers).

## Recovery and verification

Rerun the failed TestFlight job with the same Alpha run to resume. Existing group
membership, notes, and pending or approved submissions are reused. Rejected,
expired, internal-only, or non-reviewable builds fail with an explanation.
Resolve missing information, export compliance, or Apple's rejection in App Store
Connect before retrying. Apple's submission limits still apply.

Select **check_only** when running the workflow to validate the selected build
and App Store Connect setup without changing anything in TestFlight:

```sh
gh workflow run publish-ios-testflight.yml --ref main -f alpha_run_id=RUN_ID -F check_only=true
```

For the same read-only check locally with Apple credentials, repository tags,
and the Alpha artifact downloaded:

```sh
node scripts/release/promote-ios-testflight.mjs VERSION ARTIFACT_DIRECTORY RELEASE_NOTES --check
```

Supply the same Apple environment variables as Build Alpha, plus
`CODEVISOR_BUILD_NUMBER` and `CODEVISOR_SOURCE_REVISION` from the Alpha provenance.
The check verifies artifact identity and live TestFlight readiness without
creating groups, editing notes, notifying testers, or submitting a review.

App Store version submission is not part of this workflow yet.
