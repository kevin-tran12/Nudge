# syntax=docker/dockerfile:1.7

ARG RUBY_IMAGE=ruby:4.0.7-slim-trixie@sha256:d10bdb076bb10d2261773ea20eadf4cdbde3346fc8f8db409856608b2d01b9c9

FROM ${RUBY_IMAGE} AS base

WORKDIR /rails

ENV BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT=development:test \
    RAILS_LOG_TO_STDOUT=1

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y libpq5 libvips && \
    rm -rf /var/lib/apt/lists/* && \
    groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash && \
    mkdir -p log storage tmp app/assets/builds /coverage && \
    chown -R rails:rails /home/rails log storage tmp app/assets/builds /coverage

FROM base AS build

ENV BUNDLE_WITHOUT=""

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libpq-dev pkg-config && \
    rm -rf /var/lib/apt/lists/*

COPY Gemfile Gemfile.lock ./
RUN bundle install && \
    rm -rf /root/.bundle /usr/local/bundle/ruby/*/cache

COPY . .
RUN SECRET_KEY_BASE_DUMMY=1 bin/rails assets:precompile

FROM build AS production_bundle

ENV BUNDLE_WITHOUT=development:test

RUN bundle install && \
    bundle clean --force && \
    rm -rf /usr/local/bundle/ruby/*/cache

FROM build AS development

ENV HOME=/home/rails \
    RAILS_ENV=development

RUN chown -R rails:rails log storage tmp app/assets/builds

USER 1000:1000

ENTRYPOINT ["/rails/bin/docker-entrypoint"]
CMD ["bin/rails", "server", "-b", "0.0.0.0"]

FROM base AS runtime

ENV BUNDLE_DEPLOYMENT=1 \
    HOME=/home/rails \
    RAILS_ENV=production

COPY --from=production_bundle /usr/local/bundle /usr/local/bundle
COPY --from=build /rails /rails

RUN chown -R rails:rails log storage tmp

USER 1000:1000

ENTRYPOINT ["/rails/bin/docker-entrypoint"]
CMD ["bin/rails", "server", "-b", "0.0.0.0"]

HEALTHCHECK --interval=30s --timeout=3s --start-period=20s --retries=3 \
  CMD ["ruby", "-rnet/http", "-e", "exit(Net::HTTP.get_response(URI('http://127.0.0.1:3000/up')).is_a?(Net::HTTPSuccess) ? 0 : 1)"]
