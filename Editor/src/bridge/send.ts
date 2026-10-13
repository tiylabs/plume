/*
 * The page's one way to talk to Swift.
 */

import type { OutboundMessage } from "./protocol";

declare global {
  interface Window {
    webkit?: { messageHandlers?: { plume?: { postMessage(message: unknown): void } } };
  }
}

export function send(message: OutboundMessage): void {
  // Absent when the bundle is opened directly in a browser for design work, which is a legitimate
  // way to run it — so this must degrade to a no-op rather than throw.
  window.webkit?.messageHandlers?.plume?.postMessage(message);
}
