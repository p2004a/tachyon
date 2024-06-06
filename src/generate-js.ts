import fs from "node:fs";
import path from "node:path";

import { build } from "tsup";

import { generateValidators as generateJsValidators } from "@/generate-js-validators.js";
import { TachyonConfig } from "@/generate-json-schemas";
import { generateTSDefs } from "@/generate-ts-defs";

// eslint-disable-next-line no-restricted-imports
import packageJson from "../package.json";

export async function generateJs(tachyonConfig: TachyonConfig) {
    const meta = {
        version: packageJson.version,
        schema: tachyonConfig.schemaMeta,
    };

    const tempFilePath = path.join("dist", "temp.ts");
    let tempFileContent = "";
    tempFileContent += `export const tachyonMeta = ${JSON.stringify(meta, null, 4)} as const;\n\n`;

    const typeHelpers = await fs.promises.readFile("src/type-helpers.ts", "utf-8");
    tempFileContent += typeHelpers;

    await fs.promises.mkdir("dist", { recursive: true });

    await fs.promises.writeFile(tempFilePath, tempFileContent);

    await buildTs(tempFilePath);

    await fs.promises.rm(tempFilePath, { force: true });

    await generateJsValidators(tachyonConfig);

    process.stdout.write("Generating TS Defs...");
    await generateTSDefs(tachyonConfig);
    process.stdout.write("✔️\n");
}

export async function buildTs(tsPath: string) {
    await build({
        entry: {
            index: tsPath,
        },
        bundle: true,
        outDir: "dist",
        dts: true,
        format: ["cjs", "esm"],
        silent: true,
    });
}
