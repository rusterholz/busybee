FROM ruby:3.3

WORKDIR /app

# Copy gemspec and gem source (demo Gemfile references busybee via path: "../..")
COPY busybee.gemspec Gemfile ./
COPY lib/ lib/
COPY exe/ exe/

# Copy demo app
COPY spec/demo/ spec/demo/

WORKDIR /app/spec/demo
RUN bundle install

EXPOSE 3000

ENTRYPOINT ["./docker-entrypoint.sh"]
