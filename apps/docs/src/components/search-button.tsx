"use client";

import { useSearchContext } from "fumadocs-ui/contexts/search";
import { Search } from "lucide-react";

/** Sidebar search trigger with a single ⌘K keycap. The hotkey itself comes from the provider. */
export function SearchButton() {
  const { enabled, setOpenSearch } = useSearchContext();
  if (!enabled) return null;
  return (
    <button
      type="button"
      data-search-full=""
      onClick={() => setOpenSearch(true)}
      className="inline-flex items-center gap-2 rounded-lg border bg-fd-secondary/50 p-1.5 ps-2 text-sm text-fd-muted-foreground transition-colors hover:bg-fd-accent hover:text-fd-accent-foreground"
    >
      <Search className="size-4" aria-hidden="true" />
      Search
      <kbd className="ms-auto rounded-md border bg-fd-background px-1.5 py-0.5 font-mono text-xs">
        ⌘K
      </kbd>
    </button>
  );
}
