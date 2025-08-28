# deriva-docker-czi
Customized Docker container image(s) for DERIVA/CZI integration. 

## Building

The DERIVA stack image can be built with the following command, executed from the `deriva` subdirectory:
```bash
docker build -t isrddev/deriva-czi:latest .
```
Building the image is optional when using the Docker Compose project (see below), which will automatically pull the 
latest image from the DockerHub repository or build it if the specified tag does not exist.

## Testing with Docker Compose
A `docker-compose.yaml` file is provided that can be used to launch the DERIVA webserver container with a Postgres 16
container as the backing database. The compose project is meant solely for testing purposes and should not be used in a production scenario.

The compose project also requires a number of environment variables to be set in order for the container(s) to be launched successfully. 
These variables are read from a file named [test.env](./deriva/test.env.sample). Before launching the containers, 
you should copy `test.env.sample` to `test.env` and make any required deployment-specific parameter changes to the 
copied file. 

##### Note: The DERIVA webserver container image is preconfigured to use OKTA as the OIDC IDP and for authentication to function correctly `${OKTA_HOST}`, `${OKTA_CLIENT_ID}`, and `${OKTA_CLIENT_SECRET}` must all be set accordingly. 

#### Start the Stack:

```bash
docker compose --env-file test.env up
```
You can append `-d` to the above command to detach and run the stack in the background.

#### Test the Stack:
If testing locally (the default), visit `https://localhost` to verify functionality. The landing page will contain some basic links that can be used as entry points for further testing.

#### Stop the Stack:

```bash
docker compose --env-file test.env stop
```
If you ran the stack without detaching (i.e., without `-d`), you can simply `ctrl-c` to stop the stack.

Note you can also use `pause` and `unpause` to temporarily halt the container stack. Resuming from `pause` is fast and  can be useful when you want to disable the containers but then restart them quickly.
#### Delete the Stack (and optionally, associated volumes):
```bash
docker compose --env-file test.env down
```
You can append the `-v` argument (after `down`) to also delete the container volume mounts. 
Note that deleting the volume mounts will destroy any persistent state that has been created, e.g. Postgres databases, 
files in `/var/www/*` (e.g. Hatrac files and the exporter file cache).
