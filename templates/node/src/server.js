// Scaffolded for the nullplatform application __APPLICATION_SLUG__,
// in the repository __REPOSITORY_NAME__.
//
// node:http and nothing else. A dependency here would need an install step in the
// CI that came with the "Any technology" template, and the scaffolding does not
// own that file.
import { createServer } from "node:http";

// The Dockerfile sets PORT; the default is here so `npm start` works on a laptop.
const PORT = Number(process.env.PORT ?? 8080);

const server = createServer((request, response) => {
  if (request.url === "/health") {
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify({ status: "ok" }));
    return;
  }

  response.writeHead(200, { "content-type": "text/plain; charset=utf-8" });
  response.end("hello world. I am an app built in Node");
});

// 0.0.0.0 and not the default: bound to localhost the server answers inside the
// container and nowhere else, which reads as a failing health check.
server.listen(PORT, "0.0.0.0", () => {
  console.log(`__APPLICATION_SLUG__ listening on ${PORT}`);
});
