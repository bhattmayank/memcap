"""Memory fixture for memcap selftest: N workers each hold MB_EACH, every one under
the cap but their sum over it. Proves the wrapper measures the whole tree."""
import multiprocessing as mp
import sys
import time


def hold(mb):
    b = bytearray(mb * 1024 * 1024)
    for i in range(0, len(b), 4096):
        b[i] = 1
    time.sleep(30)


if __name__ == "__main__":
    workers, mb = int(sys.argv[1]), int(sys.argv[2])
    with mp.Pool(workers) as p:
        p.map(hold, [mb] * workers)
