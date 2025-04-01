# Ghibli Style Image Transformer

A web application that transforms uploaded images into Studio Ghibli-inspired artwork using a deep learning model.

## Features

- Upload images for transformation
- GPU-accelerated inference with PyTorch
- Mobile-friendly UI with image preview
- Side-by-side comparison of original and transformed images

## Technology Stack

- **Backend**: Flask (Python)
- **Frontend**: HTML, CSS, JavaScript
- **Deep Learning**: PyTorch
- **Containerization**: Docker
- **Deployment**: Kubernetes

## Local Development

### Prerequisites

- Python 3.8+
- PyTorch 2.0+
- CUDA-compatible GPU (optional, but recommended)

### Setup

1. Create a virtual environment:
   ```
   python -m venv venv
   source venv/bin/activate  # On Windows: venv\Scripts\activate
   ```

2. Install dependencies:
   ```
   pip install -r requirements.txt
   ```

3. Run the application:
   ```
   python app.py
   ```

4. Access the application at `http://localhost:5000`

## Deployment

### Using Docker

1. Build the Docker image:
   ```
   docker build -t ghibli-app:latest .
   ```

2. Run the container:
   ```
   docker run -p 5000:5000 ghibli-app:latest
   ```

### Deploying to Kubernetes

1. Edit the Docker registry in the `deploy.sh` script
2. Run the deployment script:
   ```
   ./deploy.sh
   ```

3. The application will be available at `https://ghibli.doandlearn.app`

## Model Details

The application uses a custom-trained Studio Ghibli style transfer model based on AnimeGANv2. The model is optimized for running on NVIDIA GPUs and can transform images in a few seconds.

## License

MIT License