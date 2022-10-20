# BP-DOCKER-LINTER-STEP
A BP step to do static analysis of Dockerfile, behind the scene it leverages [Hadolint](https://github.com/hadolint/hadolint)

## Setup
* Clone the code available at [BP-DOCKER-LINTER-STEP](https://github.com/OT-BUILDPIPER-MARKETPLACE/BP-DOCKER-LINTER-STEP)
* Build the docker image
```
git submodule init
git submodule update
docker build -t ot/docker_linter:0.1 .
```
* Do local testing

Debugging
```
docker run -it --rm -v $PWD:/src -e WORKSPACE=/ -e CODEBASE_DIR=src --entrypoint sh ot/docker_linter:0.1
```

If you want to use the ot_docker_linter image directly
```
docker run -it --rm -v $PWD:/src -e WORKSPACE=/ -e CODEBASE_DIR=src ot/docker_linter:0.1
```

## References
* https://github.com/hadolint/hadolint