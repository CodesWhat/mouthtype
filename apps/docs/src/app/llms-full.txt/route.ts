import { llmsOutput } from "@/lib/llms";

export const revalidate = false;
export const dynamic = "force-static";

export async function GET() {
  return new Response(await llmsOutput.full(), {
    headers: { "Content-Type": "text/plain; charset=utf-8" },
  });
}
