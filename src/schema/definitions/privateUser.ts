import { Type } from "@sinclair/typebox";

import { user } from "@/schema/definitions/user";

export const privateUser = Type.Intersect(
    [
        Type.Ref(user),
        Type.Object({
            friendIds: Type.Array(Type.String()),
            outgoingFriendRequestIds: Type.Array(Type.String()),
            incomingFriendRequestIds: Type.Array(Type.String()),
            ignoreIds: Type.Array(Type.String()),
        }),
    ],
    { $id: "privateUser" }
);
