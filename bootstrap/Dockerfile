FROM node:20-alpine
RUN apk add --no-cache bash curl jq python3
WORKDIR /bootstrap
COPY package.json /bootstrap/package.json
RUN npm ci --omit=dev || npm install --omit=dev
COPY bootstrap.sh /bootstrap/bootstrap.sh
COPY node-bootstrap.mjs /bootstrap/node-bootstrap.mjs
RUN chmod +x /bootstrap/bootstrap.sh
CMD ["/bootstrap/bootstrap.sh"]
