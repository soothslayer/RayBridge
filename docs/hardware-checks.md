# Physical-device acceptance checks

The physical-device checks below have **not** been completed. Mac ChatGPT Plus sign-in and a controlled image inference test passed (the model answered “Blue 7” for a generated blue rectangle containing a white 7). That does not establish an end-to-end working glasses assistant.

1. Sign in on the Mac with an eligible ChatGPT subscription. Verify status changes to connected; sign out and confirm the app disconnects the phone. Confirm inference never requests an API key.
2. Build and install on the intended iPhone, register the intended glasses through Meta AI, and obtain a real camera frame. Record the iPhone, iOS, glasses model, glasses firmware, Meta AI version, and account plan.
3. Pair using both QR and pasted-link flows. Check macOS/iOS local-network permission behavior. Confirm only the pinned certificate is accepted, a replaced pairing token rejects the old pairing, and the setup page is unreachable from another device.
4. With phone audio testing enabled, ask a typed nonvisual question. Then ask about a simple high-contrast object or printed label visible in the glasses camera. Verify the signed-in Codex model accepts the frame and returns a useful answer.
5. Disable phone audio testing. Confirm the actual glasses microphone receives the question and the actual glasses speakers play the answer while DAT camera streaming remains active. Measure recognition, model, and speech-start latency separately.
6. Turn the camera away, cover it, stop streaming, and disconnect the glasses. Ensure answers do not claim to see old frames. Verify unclear text produces appropriate uncertainty.
7. Unplug/disconnect Bluetooth mid-answer. Confirm speech stops rather than continuing aloud through the phone. Reconnect and repeat. Check interruptions caused by calls, Siri, VoiceOver, and other media.
8. Ask a second question after an answer. Confirm continuous turn-taking resumes. Stop while thinking and while speaking; confirm no late answer is played. Start again promptly to test cancellation races.
9. Lock/background the iPhone or sleep the Mac. Confirm the session stops/pauses visibly and audibly; foreground/reconnect and start explicitly. Test a lost network and a changed Mac IP address.
10. Navigate every setup and conversation control with VoiceOver at large Dynamic Type sizes. Verify the friend can understand connection errors, stop speech, resume, and reset without sighted assistance after initial device setup.
11. Test long answers, quiet speech, noisy rooms, silence, speech-recognition unavailability, account usage limits, and an expired sign-in. Assess whether turn latency is acceptable to the intended user.

For distribution, configure the Meta release channel, replace development identifiers, provision/sign the iPhone app, and prepare a signed/notarized Mac build appropriate to the target macOS/CPU. Developer setup is not an App Store/TestFlight release.
