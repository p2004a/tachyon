import { Type } from "@sinclair/typebox";

import { defineEndpoint } from "@/generator-helpers.js";
import { userId } from "@/schema/definitions/userId";

export default defineEndpoint({
    source: "server",
    target: "autohost",
    description: "Force players to become spectators in a battle.",
    request: {
        data: Type.Object({
            battleId: Type.String({ format: "uuid" }),
            userIds: Type.Array(Type.Ref(userId)),
        }),
    },
    response: [
        {
            status: "success",
        },
    ],
});
