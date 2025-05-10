switch("nimcache", "nimcache/" & projectName())
when defined(release):
  switch("outdir", "bin/release")
  switch("opt", "size")
  switch("passC", "-Os -flto")
  switch("passL", "-Os -flto -s")
  switch("define", "ssl")
  switch("gc", "orc")
else:
  switch("outdir", "bin/debug")