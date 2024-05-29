/* eslint-disable @typescript-eslint/no-explicit-any */

import fs from "node:fs";

import { TSchema } from "@sinclair/typebox";
import Ajv from "ajv";
import standaloneCode from "ajv/dist/standalone";
import { titleCase } from "jaz-ts-utils";

import * as types from "@/schema/definitions";

const schemaArray: TSchema[] = [];
const schemaMap: Record<string, string> = {};

for (const key in types) {
    schemaArray.push(types[key as keyof typeof types]);
    schemaMap[key] = key;
}

export async function generateValidators(schemas: TSchema) {
    for (const serviceId in schemas.properties) {
        for (const endpointId in schemas.properties[serviceId].properties) {
            for (const commandType in schemas.properties[serviceId].properties[endpointId].properties) {
                const schema = schemas.properties[serviceId].properties[endpointId].properties[commandType];
                schemaArray.push(schema);
                schemaMap[`${serviceId}_${endpointId}_${commandType}`] = `${serviceId}.${endpointId}.${commandType}`;
            }
        }
    }

    // esm
    process.stdout.write("Generating ESM validators...");
    const ajv = new Ajv({
        schemas: schemaArray,
        code: {
            source: true,
            esm: true,
        },
        keywords: ["scopes"],
    });
    let moduleCode = `"use strict"
function ucs2length(str) {
    const len = str.length;
    let length = 0;
    let pos = 0;
    let value;
    while (pos < len) {
        length++;
        value = str.charCodeAt(pos++);
        if (value >= 0xd800 && value <= 0xdbff && pos < len) {
            // high surrogate, and there is a next character
            value = str.charCodeAt(pos);
            if ((value & 0xfc00) === 0xdc00)
                pos++; // low surrogate
        }
    }
    return length;
}
`;
    moduleCode += standaloneCode(ajv, schemaMap);
    moduleCode = moduleCode.replaceAll('require("ajv/dist/runtime/ucs2length").default', "ucs2length");
    moduleCode = moduleCode.replaceAll('require("ajv-formats/dist/formats").', "");
    await fs.promises.writeFile("./dist/validators.mjs", moduleCode);
    process.stdout.write("✔️\n");

    // cjs
    process.stdout.write("Generating CJS validators...");
    const ajvCjs = new Ajv({
        schemas: schemaArray,
        code: {
            source: true,
            esm: false,
        },
        keywords: ["scopes"],
    });
    const moduleCodeCjs = standaloneCode(ajvCjs, schemaMap);
    await fs.promises.writeFile("./dist/validators.js", moduleCodeCjs);
    process.stdout.write("✔️\n");

    // types
    process.stdout.write("Generating validator types...");
    const imports: string[] = [];
    let declarations = "";
    for (const key in schemaMap) {
        const schemaType = key
            .split("_")
            .map((id) => titleCase(id))
            .join("");
        imports.push(schemaType);
        declarations += `declare const ${key}: ValidateFunction<${schemaType}>;\n`;
    }
    let types = "";
    types += `import type { ValidateFunction } from "ajv"\n`;
    types += `import { ${imports.join(", ")} } from "..";\n\n`;
    types += declarations;
    types += `\nexport { ${Object.keys(schemaMap).join(", ")} };`;

    await fs.promises.writeFile("./dist/validators.d.ts", types);
    await fs.promises.writeFile("./dist/validators.d.mts", types);
    process.stdout.write("✔️\n");
}