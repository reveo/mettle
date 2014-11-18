#include "forked_test_runner.hpp"

#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <sys/wait.h>

#include <mettle/driver/scoped_pipe.hpp>
#include <mettle/driver/test_monitor.hpp>
#include "../utils.hpp"

namespace mettle {

namespace {
  inline test_result parent_failed() {
    return { false, err_string(errno) };
  }

  [[noreturn]] inline void child_failed() {
    _exit(128);
  }
}

test_result forked_test_runner::operator ()(
  const test_function &test, log::test_output &output
) const {
  scoped_pipe stdout_pipe, stderr_pipe, log_pipe;
  if(stdout_pipe.open() < 0 ||
     stderr_pipe.open() < 0 ||
     log_pipe.open(O_CLOEXEC) < 0)
    return parent_failed();

  fflush(nullptr);

  pid_t pid;
  if((pid = fork()) < 0)
    return parent_failed();

  if(pid == 0) {
    // Make a new process group so we can kill the test and all its children
    // as a group.
    pid_t old_pgid = getpgid(0);
    setpgid(0, 0);
    pid_t new_pgid = getpgid(0);

    if(timeout_)
      fork_monitor(*timeout_);

    if(stdout_pipe.close_read() < 0 ||
       stderr_pipe.close_read() < 0 ||
       log_pipe.close_read() < 0)
      child_failed();

    if(stdout_pipe.move_write(STDOUT_FILENO) < 0 ||
       stderr_pipe.move_write(STDERR_FILENO) < 0)
      child_failed();

    auto result = test();
    if(write(log_pipe.write_fd, result.message.c_str(),
             result.message.length()) < 0)
      child_failed();

    fflush(nullptr);

    // Leave our process group and kill any children. Don't worry about reaping.
    setpgid(0, old_pgid);
    kill(-new_pgid, SIGKILL);
    _exit(!result.passed);
  }
  else {
    if(stdout_pipe.close_write() < 0 ||
       stderr_pipe.close_write() < 0 ||
       log_pipe.close_write() < 0)
      return parent_failed();

    ssize_t size;
    char buf[BUFSIZ];

    // Read from the piped stdout and stderr.
    int rv;
    pollfd fds[2] = { {stdout_pipe.read_fd, POLLIN, 0},
                      {stderr_pipe.read_fd, POLLIN, 0} };
    std::string *dests[] = {&output.stdout, &output.stderr};
    int open_fds = 2;
    while(open_fds && (rv = poll(fds, 2, -1)) > 0) {
      for(size_t i = 0; i < 2; i++) {
        if(fds[i].revents & POLLIN) {
          if((size = read(fds[i].fd, buf, sizeof(buf))) < 0)
            return parent_failed();
          dests[i]->append(buf, size);
        }
        if(fds[i].revents & POLLHUP) {
          fds[i].fd = -fds[i].fd;
          open_fds--;
        }
      }
    }
    if(rv < 0) // poll() failed!
      return parent_failed();

    // Read from our logging pipe (which sends the message from the test run).
    std::string message;
    while((size = read(log_pipe.read_fd, buf, sizeof(buf))) > 0)
      message.append(buf, size);
    if(size < 0) // read() failed!
      return parent_failed();

    int status;
    if(waitpid(pid, &status, 0) < 0)
      return parent_failed();

    if(WIFEXITED(status)) {
      int exit_code = WEXITSTATUS(status);
      if(exit_code == err_timeout) {
        std::ostringstream ss;
        ss << "Timed out after " << timeout_->count() << " ms";
        return { false, ss.str() };
      }
      else {
        return { exit_code == 0, message };
      }
    }
    else { // WIFSIGNALED
      return { false, strsignal(WTERMSIG(status)) };
    }
  }
}

} // namespace mettle
