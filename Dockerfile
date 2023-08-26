FROM alpine:3.18 as build
COPY ./docker-assets/repositories /etc/apk/repositories
RUN ["apk", "update"]
RUN apk add zig
COPY ./linksaver /build
WORKDIR /build
RUN zig build -Doptimize=ReleaseSafe -j8

FROM alpine:3.18
COPY --from=build /build/zig-out/bin/a /bin/linksaver
CMD ["/bin/linksaver"]