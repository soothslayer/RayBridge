// Actionable spoken errors.
//
// Every failure the user can hear carries what happened AND what to do about
// it. The bridge sends { type: 'error', code, message, fix }; the phone speaks
// the message followed by the fix when one is present. Codes are stable so the
// phone (and tests) can rely on them; wording stays here so voice phrasing is
// consistent. Nothing spoken includes question text, answer text, images, or
// account details.

export const ERROR_CATALOG = {
  // The assistant was reachable but its subscription login is missing.
  'assistant.signed-out': {
    message: 'The assistant is not signed in on your Mac.',
    fix: '',
  },
  // A turn ran and failed (or came back empty) after the question was accepted.
  'turn.failed': {
    message: 'The answer was interrupted or empty.',
    fix: 'Try asking again. If it keeps failing, reopen RayBridge on your Mac and say start.',
  },
  // A question arrived while another answer was still in progress.
  'turn.busy': {
    message: 'An answer is already in progress.',
    fix: 'Wait for it to finish, or say cancel to stop it and ask something else.',
  },
  // The question text was empty, blank, or over the length limit.
  'question.invalid': {
    message: 'Please ask a question of 1 to 4000 characters.',
    fix: '',
  },
  // The camera frame was not a usable JPEG or exceeded the size limit.
  'frame.invalid': {
    message: 'The camera image could not be used.',
    fix: 'Try asking again.',
  },
  // Anything else the phone sent that the bridge could not handle.
  'message.invalid': {
    message: 'The Mac could not handle that request.',
    fix: 'Try asking again. If it keeps failing, reopen RayBridge on your Mac.',
  },
};

// The fix for a missing sign-in depends on which assistant is selected,
// because each one is authorized a different way on the Mac.
export function signOutFix(provider) {
  if (provider === 'claude')
    return 'On your Mac, open Terminal and run claude auth login, then ask again.';
  if (provider === 'hermes')
    return 'On your Mac, finish setting up Hermes, then ask again.';
  return 'On your Mac, open the RayBridge setup page and sign in with ChatGPT, then ask again.';
}

export function errorEvent(code, { message, fix } = {}) {
  const entry = ERROR_CATALOG[code] || {};
  return {
    type: 'error',
    code,
    message: message ?? entry.message ?? 'The Mac reported an error.',
    fix: fix ?? entry.fix ?? '',
  };
}

// Thrown bridge errors carry their code and fix so the websocket layer can
// forward them as structured error events instead of bare messages.
export function codedError(code, message, fix) {
  const event = errorEvent(code, { message, fix });
  const error = new Error(event.message);
  error.code = event.code;
  error.fix = event.fix;
  return error;
}
