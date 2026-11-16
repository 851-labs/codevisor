export const GREETING_OPENING = '<codevisor-event type="bot.created">'

export const greetingText: string = [
  GREETING_OPENING,
  "The user just created you and hasn't written to you yet. Introduce yourself now: send a " +
    "short hello, then a second message that asks what they'd like you to do.",
  "</codevisor-event>"
].join("\n")
