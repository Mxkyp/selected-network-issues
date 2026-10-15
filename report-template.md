> Lodz University of Technology
> Faculty of Technical Physics, Information Technology and Applied Mathematics
> Institute of Information Technology

> Selected Issues of Network Applications
> 2025/2026

# Project topic

Group members (Name and surname, index number)

```
Name and surname, index number
```
# The problem

## 1. Problem description

### *I. Definition of the problem that the group aims to solve.*

### *II. Description and justification of the proposed solution – how it contributes to the current state-of-the-art and how significant this project is.*

### *III. Brief analysis of the advantages and disadvantages of the existing alternatives.*
        
## 2. Selected tools

*Explanation of the functionalities of the tools and technologies planned to use, with a justification of how they allow one to tackle the problem under consideration.*

* **k3d:** A lightweight Kubernetes distribution that runs Kubernetes clusters inside Docker containers. It allows setting up a cluster inside single-node environments or on a local machine (e.g., PC). Also removes the need of using paid cloud k8s engines (e.g., AKS EKS, GKS)
* **Linkerd:** An ultra-lightweight Service Mesh that provides automatic mTLS encryption, service identity verification, and granular Zero-Trust access control policies without requiring application code changes.
* **Grafana:** A visualization dashboard platform providing real-time insights into collected metrics. Charts, graphs, and visual metrics will highlight the new functionalities provided by the Service Mesh.
* **Prometheus / VictoriaMetrics:** Time-series databases collecting network metrics and policy audit logs from Service Mesh services. They provide the data needed to audit system health and verify policy enforcement during attack simulations.
* **Example microservice application (e.g., Google Online Boutique):** A distributed application serving as a testing environment for the proposed solution. 

## 3. Functional requirements

*Description of the required project functionalities.*

## 4. Schedule

*Schedule of the development process involving the order and deadlines of all the partial steps of the project realization.*

1. Set up the k3d cluster and deploy the example microservice application (e.g., Google Online Boutique) [Week 3-4]
2. Deploy a Service Mesh solution (Linkerd) with a basic configuration to demonstrate encrypted service-to-service communication (mTLS) and basic traffic verification as a Proof of Concept [Week 5-6] – **Deadline: 6.11.2026**
3. Design and implement strict Zero-Trust access policies in Linkerd [Week 7]
4. Integrate Grafana and Prometheus with Linkerd for continuous security and traffic monitoring [Week 8]
5. Prepare and run simple attack simulation on the application infrastructure to present increased security and visibility of the microservice network layer [Week 9] – **Deadline: 27.11.2026**

## 5. Work division

*Description of the responsibilities of each group member. A few people may be responsible for the same project aspect, while one person may be in charge of multiple aspects. The key is to share the work evenly among the group members.*
 
| Member               | Responsibility                                                                                                                                                   |
|----------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Mikołaj Pawłoś       | Set up the Kubernetes (k3d) cluster and deploying the example microservice application                                                                           |  
| Jędrzej Bartoszewski | Integrating a Service Mesh solution (Linkerd) into the app environment, basic configuration for mTLS and POC purposes                                            |   
| Michał Domagała      | Designing and launching the attacks on the enhanced version of the system's environment as a live-proof, implementing Zero-Trust access policies in Service Mesh |   
| Kacper Maziarz       | Integrate visualising, log- and metrics-aggregating tools with the Service Mesh solution*                                                                        |   

------------------------------------------------------------------------------------------------------------------------------------------------