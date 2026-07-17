proc client() =
  capture n:
    socket.send(frame).addCallback proc(f: Future[void]) =
      assert not f.failed
      echo "SENT #", n
      if n != completedCount + 1:
        echo "mismatch"
      completedCount = n
  await sleepAsync 1
