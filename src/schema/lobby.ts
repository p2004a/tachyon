import { Type } from "@sinclair/typebox";

import { Endpoint, schemaRef } from "../helpers";
import { lobby } from "./types";

export const lobbyEndpoints: Record<string, Endpoint> = {
    list_lobbies: {
        request: Type.Object({}),
        response: Type.Array(schemaRef(lobby))
    },
    get: {
        request: Type.Object({}),
        response: Type.Object({})
    },
    join: {
        request: Type.Object({}),
        response: Type.Object({})
    },
    leave: {
        request: Type.Object({}),
        response: Type.Object({})
    },
    update_status: {
        request: Type.Object({}),
        response: Type.Object({})
    },
    
    // Server updates not behind a listener
    updated: {
        response: Type.Object({})
    },
    joined: {
        response: Type.Object({})
    },
    add_user: {
        response: Type.Object({})
    },
    remove_user: {
        response: Type.Object({})
    },
    bot_added: {
        response: Type.Object({})
    },
    bot_updated: {
        response: Type.Object({})
    },
    bot_removed: {
        response: Type.Object({})
    },

    // Server updates, should be behind a listener
    opened: {
        response: Type.Object({})
    },
    closed: {
        response: Type.Object({})
    }
};
