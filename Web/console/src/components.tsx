import type { ButtonHTMLAttributes, HTMLAttributes, PropsWithChildren } from "react";
import { cn } from "./lib";

export function Button({ className, ...props }: ButtonHTMLAttributes<HTMLButtonElement>) {
  return <button className={cn("button", className)} {...props} />;
}

export function Card({ className, ...props }: HTMLAttributes<HTMLDivElement>) {
  return <div className={cn("card", className)} {...props} />;
}

export function Badge({ tone = "neutral", children }: PropsWithChildren<{ tone?: "neutral" | "good" | "warn" }>) {
  return <span className={`badge badge-${tone}`}>{children}</span>;
}

export function Metric({ label, value }: { label: string; value: string }) {
  return <Card className="metric"><span>{label}</span><strong>{value}</strong></Card>;
}
