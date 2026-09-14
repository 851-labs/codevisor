// Kept inline with the server-rendered page: no client framework or external assets.
// All dynamic user-facing values enter the DOM through textContent or input.value.
export const loginScript = String.raw`
(() => {
  const el = (id) => document.getElementById(id);
  const root = el("auth");
  const redirect = root.dataset.redirect;
  const form = el("email-auth");
  const error = el("auth-error");
  if (new URLSearchParams(location.search).has("error")) {
    error.textContent = "Sign-in wasn’t completed. Please try again or use another sign-in method.";
    error.hidden = false;
  }
  if (!form) return;
  const email = el("email");
  const password = el("password");
  const code = el("code");
  const fields = el("auth-fields");
  const notice = el("auth-notice");
  const submit = el("auth-submit");
  const show = (id, visible) => { const node = el(id); if (node) node.hidden = !visible; };
  let step = "sign-in";
  let busy = false;
  let verificationOrigin = "sign-in";
  const screens = {
    "sign-in": ["Sign in to Codevisor", root.dataset.subtitle, "Sign in", "Signing in…"],
    "sign-up": ["Create your account", "One account for all your machines.", "Create account", "Creating account…"],
    "verify-email": ["Check your email", "We sent a verification code to", "Verify email", "Verifying…"],
    "forgot-password": ["Forgot your password?", "We’ll email you a code to reset it.", "Send reset code", "Sending code…"],
    "reset-password": ["Set a new password", "If an account exists, a reset code is on its way to", "Reset password", "Resetting password…"],
    "password-reset": ["Password updated", "You’re ready to sign in with your new password.", "Back to sign in", "Back to sign in"]
  };
  const clearFeedback = () => { error.hidden = true; notice.hidden = true; };
  const showError = (message) => {
    error.textContent = message;
    error.hidden = false;
    error.focus();
  };
  const showFailure = (failure) => {
    if (failure.code === "EMAIL_DELIVERY_FAILED" && step === "verify-email") {
      el("auth-subtitle").textContent = "Your account is waiting for email verification.";
    }
    showError(failure.message);
  };
  const render = (next, focus = true) => {
    step = next;
    const signingIn = step === "sign-in";
    const signingUp = step === "sign-up";
    const verifying = step === "verify-email";
    const resetting = step === "reset-password";
    const done = step === "password-reset";
    const needsEmail = signingIn || signingUp || step === "forgot-password";
    const needsPassword = signingIn || signingUp || resetting;
    const needsCode = verifying || resetting;
    form.querySelectorAll("[aria-invalid]").forEach(input => input.removeAttribute("aria-invalid"));
    password.value = "";
    password.type = "password";
    code.value = "";
    el("show-password").textContent = "Show";
    el("show-password").setAttribute("aria-label", "Show password");
    el("show-password").setAttribute("aria-pressed", "false");
    el("auth-title").textContent = screens[step][0];
    document.title = screens[step][0] + " · " + root.dataset.instance;
    el("auth-subtitle").textContent = screens[step][1];
    el("auth-address").textContent = email.value;
    el("auth-submit-label").textContent = screens[step][busy ? 3 : 2];
    const divider = el("auth-divider")?.firstElementChild;
    if (divider) divider.textContent = signingUp ? "or sign up with email" : "or continue with email";
    show("auth-providers", signingIn || signingUp);
    show("auth-divider", signingIn || signingUp);
    show("email-field", needsEmail);
    show("password-field", needsPassword);
    show("code-field", needsCode);
    show("auth-address", needsCode);
    show("forgot-password", signingIn);
    show("password-hint", signingUp || resetting);
    show("auth-code-actions", needsCode);
    show("auth-signup", signingIn);
    show("auth-signin", signingUp);
    show("auth-back", !signingIn && !signingUp && !done);
    show("auth-success", done);
    show("dev-login", signingIn);
    email.disabled = !needsEmail;
    email.required = needsEmail;
    password.disabled = !needsPassword;
    password.required = needsPassword;
    code.disabled = !needsCode;
    code.required = needsCode;
    password.autocomplete = signingIn ? "current-password" : "new-password";
    if (signingIn) {
      password.removeAttribute("minlength");
      password.removeAttribute("maxlength");
      password.removeAttribute("aria-describedby");
    } else {
      password.minLength = 8;
      password.maxLength = 128;
      password.setAttribute("aria-describedby", "password-hint");
    }
    el("password-label").textContent = resetting ? "New password" : "Password";
    const back = el("auth-back-link");
    const backStep = verifying ? verificationOrigin : resetting ? "forgot-password" : "sign-in";
    back.dataset.step = backStep;
    back.textContent = needsCode ? "Use a different email" : "Back to sign in";
    back.href = "/login?" + new URLSearchParams({ redirect, step: backStep });
    if (focus) el("auth-title").focus();
  };
  const navigate = (next, replace = false) => {
    clearFeedback();
    render(next);
    const url = new URL(location.href);
    url.searchParams.delete("error");
    url.searchParams.set("step", next);
    history[replace ? "replaceState" : "pushState"]({ step: next }, "", url);
  };
  const setBusy = (value) => {
    busy = value;
    fields.disabled = value;
    form.setAttribute("aria-busy", String(value));
    submit.classList.toggle("is-loading", value);
    el("auth-submit-label").textContent = screens[step][value ? 3 : 2];
    root.querySelectorAll("a").forEach(link => {
      if (value) link.setAttribute("aria-disabled", "true");
      else link.removeAttribute("aria-disabled");
    });
  };
  const messages = {
    INVALID_EMAIL: "Enter a valid email address.",
    INVALID_EMAIL_OR_PASSWORD: "The email or password is incorrect.",
    INVALID_PASSWORD: "The email or password is incorrect.",
    USER_ALREADY_EXISTS: "An account already uses this email. Sign in or reset your password.",
    USER_ALREADY_EXISTS_USE_ANOTHER_EMAIL: "An account already uses this email. Sign in or reset your password.",
    INVALID_OTP: "That code is incorrect or expired. Try again or request a new code.",
    OTP_EXPIRED: "That code has expired. Request a new code.",
    VERIFICATION_CODE_NOT_FOUND: "That code is incorrect or expired. Request a new code.",
    TOO_MANY_ATTEMPTS: "Too many incorrect attempts. Request a new code.",
    PASSWORD_TOO_SHORT: "Use at least 8 characters for your password.",
    PASSWORD_TOO_LONG: "Use 128 characters or fewer for your password.",
    EMAIL_DELIVERY_FAILED: "We couldn’t send your code. Please try resending it."
  };
  const request = async (path, body) => {
    let response;
    try {
      response = await fetch("/api/auth/" + path, {
        method: "POST", credentials: "same-origin",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(body), signal: AbortSignal.timeout(30000)
      });
    } catch {
      throw new Error("Couldn’t reach Codevisor. Check your connection and try again.");
    }
    const result = await response.json().catch(() => ({}));
    if (!response.ok) {
      const failure = new Error(response.status === 429
        ? "Too many attempts. Please wait a minute and try again."
        : messages[result.code] || "Something went wrong. Please try again.");
      failure.code = result.code;
      throw failure;
    }
    return result;
  };
  const sendCode = () => step === "verify-email"
    ? request("email-otp/send-verification-otp", { email: email.value, type: "email-verification" })
    : request("email-otp/request-password-reset", { email: email.value });
  root.addEventListener("click", event => {
    const link = event.target.closest("a");
    if (!link) return;
    if (busy) { event.preventDefault(); return; }
    if (link.dataset.step && !event.metaKey && !event.ctrlKey && !event.shiftKey && !event.altKey) {
      event.preventDefault();
      navigate(link.dataset.step);
    }
  });
  window.addEventListener("popstate", () => {
    // A request may have committed already; don't let its result overwrite a different screen.
    // Reload abandons this document and resumes from the server's safe entry screens.
    if (busy) { location.reload(); return; }
    let next = new URLSearchParams(location.search).get("step") || "sign-in";
    if (!Object.hasOwn(screens, next) || ((next === "verify-email" || next === "reset-password") && !email.value)) next = "sign-in";
    clearFeedback();
    render(next);
  });
  el("show-password").addEventListener("click", () => {
    const showing = password.type === "password";
    password.type = showing ? "text" : "password";
    el("show-password").textContent = showing ? "Hide" : "Show";
    el("show-password").setAttribute("aria-label", showing ? "Hide password" : "Show password");
    el("show-password").setAttribute("aria-pressed", String(showing));
  });
  code.addEventListener("input", () => { code.value = code.value.replace(/[^0-9]/g, "").slice(0, 6); });
  form.addEventListener("invalid", event => { event.target.setAttribute("aria-invalid", "true"); }, true);
  form.addEventListener("input", event => { event.target.removeAttribute("aria-invalid"); });
  el("resend-code").addEventListener("click", async () => {
    if (busy) return;
    clearFeedback();
    setBusy(true);
    try {
      await sendCode();
      code.value = "";
      el("auth-subtitle").textContent = screens[step][1];
      notice.textContent = "A new code is on its way. Use the most recent code.";
      notice.hidden = false;
    } catch (failure) { showFailure(failure); }
    finally { setBusy(false); }
  });
  form.addEventListener("submit", async event => {
    event.preventDefault();
    if (busy || !form.reportValidity()) return;
    if (step === "password-reset") { navigate("sign-in", true); return; }
    email.value = email.value.trim().toLowerCase();
    clearFeedback();
    setBusy(true);
    let leaving = false;
    try {
      if (step === "sign-in") {
        try {
          await request("sign-in/email", { email: email.value, password: password.value });
          leaving = true;
        } catch (failure) {
          if (failure.code !== "EMAIL_NOT_VERIFIED") throw failure;
          verificationOrigin = "sign-in";
          navigate("verify-email");
          await sendCode();
        }
      } else if (step === "sign-up") {
        verificationOrigin = "sign-up";
        try {
          await request("sign-up/email", { email: email.value, password: password.value, name: email.value.split("@")[0] });
        } catch (failure) {
          // Mail failure can leave a pending account. Keep verification/resend reachable.
          if (failure.code === "EMAIL_DELIVERY_FAILED") navigate("verify-email");
          throw failure;
        }
        navigate("verify-email");
      } else if (step === "verify-email") {
        await request("email-otp/verify-email", { email: email.value, otp: code.value });
        leaving = true;
      } else if (step === "forgot-password") {
        await request("email-otp/request-password-reset", { email: email.value });
        navigate("reset-password");
      } else if (step === "reset-password") {
        await request("email-otp/reset-password", { email: email.value, otp: code.value, password: password.value });
        navigate("password-reset", true);
      }
      if (leaving) {
        password.value = "";
        code.value = "";
        location.replace(redirect);
      }
    } catch (failure) { showFailure(failure); }
    finally { if (!leaving) setBusy(false); }
  });
  window.addEventListener("pagehide", () => { password.value = ""; code.value = ""; });
  window.addEventListener("pageshow", event => { if (event.persisted) setBusy(false); });
  const initial = new URLSearchParams(location.search).get("step");
  render(initial === "sign-up" || initial === "forgot-password" ? initial : "sign-in", false);
  submit.disabled = false;
})();
`
