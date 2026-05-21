# Custom Slinky login image: adds core developer tools so the LoginSet pod
# is actually usable. The upstream login image ships only the Slurm client
# commands (sinfo, srun, sbatch, ...) — it has no editor, git, python, sudo,
# or curl/wget, so users can't pull a codebase, edit a file, run a script, or
# install software. This image layers those tools on top.
#
# Base tag matches the rest of the stack (25.11.5-ubuntu24.04).
FROM ghcr.io/slinkyproject/login:25.11.5-ubuntu24.04

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
        vim \
        nano \
        git \
        python3 \
        python3-pip \
        sudo \
        curl \
        wget \
        less \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# PoC convenience: passwordless sudo for interactive login users so they can
# run apt etc. Login pods authenticate real users dynamically via PAM/sackd,
# so we grant sudo broadly. Tighten this for production.
RUN echo 'ALL ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/99-slinky-login \
    && chmod 0440 /etc/sudoers.d/99-slinky-login
