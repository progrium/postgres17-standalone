# The web demo's login shell: /root, with minipg on PATH.
export PSQL_PAGER= PS1='\[\e[1;34m\]\w\[\e[0m\] \$ '
cd /root
cat <<'MSG'
minipg: PostgreSQL as a single executable. This is minipg with Postgres 18 for 386
Linux, running in your browser under h9.

Try:
  minipg app.pgdb                       psql (creates app.pgdb)
  minipg app.pgdb "select version()"    one statement
  minipg url app.pgdb                   a URL for apps
  minipg dump app.pgdb                  pg_dump
  minipg status app.pgdb
  minipg                                every command

MSG
