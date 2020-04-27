# vi:syntax=python

load("/starlark/stable/pipeline", "git_checkout_dir", "image_resource", "storage_resource")

__doc__ = """
# Go

Provides methods for building and testing Go modules.

To import, add the following to your Dispatchfile:

```
load("github.com/mesosphere/dispatch-catalog/starlark/stable/go@0.0.5", "go")
```
"""

def go_test(task_name, git_name, paths=["./..."], image="golang:1.14", inputs=[], outputs=[], steps=[], **kwargs):
    """
    Run Go tests and generate a coverage report.
    """

    # TODO(chhsiao): Because the location is deterministic, artifacts will be overwritten by
    # different runs. We should introduce a mechanism to avoid this.
    storage_name = storage_resource(
        "storage-{}".format(task_name),
        location="s3://artifacts/{}/".format(task_name)
    )

    inputs = inputs + [git_name]
    outputs = outputs + [storage_name]
    steps = steps + [
        k8s.corev1.Container(
            name="go-test",
            image=image,
            command=["sh", "-c", """\
set -xe
go test -v -coverprofile $(resources.outputs.{storage}.path)/coverage.out {paths}
go tool cover -func $(resources.outputs.{storage}.path)/coverage.out | tee $(resources.outputs.{storage}.path)/coverage.txt
diff -uN --label old/coverage.txt --label new/coverage.txt coverage.txt $(resources.outputs.{storage}.path)/coverage.txt || true
            """.format(
                storage=storage_name,
                paths=" ".join(paths)
            )],
            env=[k8s.corev1.EnvVar(name="GO111MODULE", value="on")],
            workingDir=git_checkout_dir(git_name)
        )
    ]

    task(task_name, inputs=inputs, outputs=outputs, steps=steps, **kwargs)

    return storage_name

def go(task_name, git_name, paths=["./..."], image="golang:1.14", ldflags=None, os=["linux"], arch=["amd64"], inputs=[], outputs=[], steps=[], **kwargs):
    """
    Build a Go binary.
    """

    # TODO(chhsiao): Because the location is deterministic, artifacts will be overwritten by
    # different runs. We should introduce a mechanism to avoid this.
    storage_name = storage_resource(
        "storage-{}".format(task_name),
        location="s3://artifacts/{}/".format(task_name)
    )

    inputs = inputs + [git_name]
    outputs = outputs + [storage_name]

    build_args = []
    if ldflags:
        build_args += ["-ldflags", ldflags]

    for goos in os:
        for goarch in arch:
            steps = steps + [
                k8s.corev1.Container(
                    name="go-build-{}-{}".format(goos, goarch),
                    image=image,
                    command=["sh", "-c", """\
mkdir -p $(resources.outputs.{storage}.path)/{os}_{arch}/
go build -o $(resources.outputs.{storage}.path)/{os}_{arch}/ {build_args} {paths}
                    """.format(
                        storage=storage_name,
                        os=goos,
                        arch=goarch,
                        build_args=" ".join(build_args),
                        paths=" ".join(paths)
                    )],
                    env=[
                        k8s.corev1.EnvVar(name="GO111MODULE", value="on"),
                        k8s.corev1.EnvVar(name="GOOS", value=goos),
                        k8s.corev1.EnvVar(name="GOARCH", value=goarch)
                    ],
                    workingDir=git_checkout_dir(git_name)
                )
            ]

    task(task_name, inputs=inputs, outputs=outputs, steps=steps, **kwargs)

    return storage_name

def ko(task_name, git_name, image_repo, path, tag="$(context.build.name)", ldflags=None, inputs=[], outputs=[], steps=[], **kwargs):
    """
    Build a Docker container for a Go binary using ko.
    """

    image_name = image_resource(
        "image-{}".format(task_name),
        url=image_repo
    )

    inputs = inputs + [git_name]
    outputs = outputs + [image_name]

    env = [
        k8s.corev1.EnvVar(name="GO111MODULE", value="on"),
        k8s.corev1.EnvVar(name="KO_DOCKER_REPO", value="-") # This value is arbitrary to pass ko's validation.
    ]

    if ldflags:
        env.append(k8s.corev1.EnvVar(name="GOFLAGS", value="-ldflags={}".format(ldflags)))

    steps = steps + [
        k8s.corev1.Container(
            name="build",
            image="gcr.io/tekton-releases/dogfooding/ko:latest",
            command=[
                "ko", "publish",
                "--oci-layout-path=$(resources.outputs.{}.path)".format(image_name),
                "--push=false",
                path
            ],
            env=env,
            workingDir=git_checkout_dir(git_name),
        ),
        k8s.corev1.Container(
            name="push",
            image="gcr.io/tekton-releases/dogfooding/skopeo:latest",
            command=[
                "skopeo", "copy",
                "oci:$(resources.outputs.{}.path)/".format(image_name),
                "docker://$(resources.outputs.{}.url):{}".format(image_name, tag)
            ],
        )
    ]

    task(task_name, inputs=inputs, outputs=outputs, steps=steps, **kwargs)

    return image_name
