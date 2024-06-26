import { Type } from "@sinclair/typebox";

export const userId = Type.String({
    $id: "userId",
    format: "uuid",
    examples: ["f47a7e1e-4b2f-4d3d-3f3c-1f0f0e4b7e1e"],
});
