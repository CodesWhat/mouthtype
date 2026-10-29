/** Quiet brand credit for the sidebar footer, next to the theme button. */
export function CodesWhatCredit() {
  return (
    <p className="min-w-0 flex-1 text-xs leading-snug text-fd-muted-foreground">
      <a
        href="https://codeswhat.com"
        className="underline underline-offset-2 transition-colors hover:text-fd-accent-foreground"
      >
        CodesWhat
      </a>
      : small, sharp tools from one developer and a lot of agents.
    </p>
  );
}
