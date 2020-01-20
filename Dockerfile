FROM alpine:3.11

ENV API_VERSION=5.1

RUN apk add --no-cache bash curl jq git sed coreutils 

ADD script.sh /bin/

CMD script.sh
