import { describe, expect, it } from "vitest";
import { formatBytes } from "./lib";

describe("formatBytes", () => {
  it("formats byte and binary units", () => {
    expect(formatBytes(42)).toBe("42 B");
    expect(formatBytes(1536)).toBe("1.5 KB");
    expect(formatBytes(2 * 1024 * 1024)).toBe("2.0 MB");
  });
});
