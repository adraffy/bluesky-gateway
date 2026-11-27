// bun src/serve.ts   (env: PORT=8016)

import { serveEZCCIP } from '@adraffy/ezccip/serve';
import { createGateway } from './gateway.js';

await serveEZCCIP(createGateway(), { port: Number(process.env.PORT ?? 8016) });
