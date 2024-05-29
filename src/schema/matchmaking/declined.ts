import { defineEndpoint } from "@/generator-helpers.js";

export default defineEndpoint({
    source: "user",
    target: "server",
    description: "Sent when a found match is declined, either by manual rejection or timeout from any user in the queue.",
    request: {},
    response: [
        {
            status: "success",
        },
    ],
});