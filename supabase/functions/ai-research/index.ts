import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import Anthropic from "npm:@anthropic-ai/sdk@0.39.0";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { status: 200, headers: corsHeaders });
  }

  try {
    const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
    if (!apiKey) {
      throw new Error("ANTHROPIC_API_KEY not configured");
    }

    const { idea } = await req.json();
    if (!idea || typeof idea !== "string") {
      return new Response(JSON.stringify({ error: "idea is required" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const client = new Anthropic({ apiKey });

    const prompt = `You are an expert in Stonebranch Universal Automation Center (UAC) Universal Extensions.
A user wants to create a new extension. Based on their description, research the target service and fill in the details.

User's idea:
${idea}

Research the target service's API, authentication methods, and capabilities using your knowledge. Then respond with a JSON object (no markdown fences, just raw JSON) with these fields:

{
  "title": "A clear, descriptive title for the extension",
  "target_service": "The name of the target service/platform",
  "integration_type": "rest_api or cli (pick the most appropriate)",
  "priority": "low, medium, high, or critical based on the use case",
  "description": "A comprehensive description including: overview, key operations & features (as bullet points), authentication approach, error handling considerations, and any important technical notes. Make it detailed and actionable.",
  "api_info": "Relevant API documentation URLs, endpoint references, and authentication documentation links"
}

IMPORTANT:
- The description should be detailed with specific operations, not vague
- Include specific API endpoints or CLI commands if known
- Mention authentication methods (API key, OAuth, etc.)
- List 3-5 concrete actions/operations the extension should support
- Include error handling and edge case considerations
- Return ONLY the JSON object, no other text`;

    const message = await client.messages.create({
      model: "claude-sonnet-4-6",
      max_tokens: 4096,
      messages: [{ role: "user", content: prompt }],
    });

    const text =
      message.content[0].type === "text" ? message.content[0].text : "";

    // Parse JSON from response
    let result;
    try {
      result = JSON.parse(text.trim());
    } catch {
      // Try extracting from code fence
      const match = text.match(/```(?:json)?\s*\n?(.*?)\n?```/s);
      if (match) {
        result = JSON.parse(match[1].trim());
      } else {
        // Try finding first { to last }
        const start = text.indexOf("{");
        const end = text.lastIndexOf("}");
        if (start !== -1 && end > start) {
          result = JSON.parse(text.slice(start, end + 1));
        } else {
          throw new Error("Could not parse AI response as JSON");
        }
      }
    }

    return new Response(JSON.stringify(result), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (err) {
    return new Response(JSON.stringify({ error: err.message }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
