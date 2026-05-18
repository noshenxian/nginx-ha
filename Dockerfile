FROM openresty/openresty:1.27.1.2-0-alpine

WORKDIR /gateway

COPY AGENTS.md README.md start.sh ./
COPY conf ./conf
COPY lua ./lua
COPY scripts ./scripts
COPY tests ./tests

RUN chmod +x start.sh scripts/*.sh tests/*.sh

ENV GATEWAY_BIND=0.0.0.0:8080
ENV NGINX_BIN=/usr/local/openresty/nginx/sbin/nginx
EXPOSE 8080

CMD ["./start.sh"]
